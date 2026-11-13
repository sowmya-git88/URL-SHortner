// Project 13 — Go jobs API. Writes jobs to Postgres; the Python worker processes them.
//   /livez       liveness  (process is alive; NO dependency checks)
//   /api/health  readiness (can reach Postgres → receive traffic)
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

type Job struct {
	ID          int64           `json:"id"`
	Input       string          `json:"input"`
	Status      string          `json:"status"`
	Result      json.RawMessage `json:"result"`
	Error       *string         `json:"error"`
	Attempts    int             `json:"attempts"`
	SubmittedBy *string         `json:"submitted_by"`
	ProcessedBy *string         `json:"processed_by"`
	CreatedAt   time.Time       `json:"created_at"`
	FinishedAt  *time.Time      `json:"finished_at"`
}

var (
	db       *sql.DB
	podName  = envOr("POD_NAME", hostname())
	logger   = slog.New(slog.NewJSONHandler(os.Stdout, nil))
	started  = time.Now()
	draining atomic.Bool
)

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func hostname() string {
	h, _ := os.Hostname()
	return h
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Served-By", podName)
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	var err error
	db, err = sql.Open("pgx", os.Getenv("DATABASE_URL"))
	if err != nil {
		logger.Error("open db", "err", err)
		os.Exit(1)
	}
	db.SetMaxOpenConns(5)
	db.SetConnMaxIdleTime(time.Minute)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"alive": true, "pod": podName})
	})
	mux.HandleFunc("GET /api/health", health)
	mux.HandleFunc("GET /api/jobs", listJobs)
	mux.HandleFunc("POST /api/jobs", createJob)
	mux.HandleFunc("GET /api/jobs/{id}", getJob)
	mux.HandleFunc("GET /api/stats", stats)

	srv := &http.Server{
		Addr:              ":" + envOr("PORT", "8080"),
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		logger.Info("listening", "addr", srv.Addr, "pod", podName)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server", "err", err)
			os.Exit(1)
		}
	}()
	<-ctx.Done()

	// Kubernetes: the pod is removed from Service endpoints *asynchronously*. Fail readiness
	// first and keep serving a few seconds so in-flight and late-routed requests still succeed.
	draining.Store(true)
	logger.Info("SIGTERM: failing readiness, draining 5s")
	time.Sleep(5 * time.Second)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	_ = db.Close()
	logger.Info("bye")
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t0 := time.Now()
		next.ServeHTTP(w, r)
		if r.URL.Path != "/livez" && r.URL.Path != "/api/health" {
			logger.Info("request", "method", r.Method, "path", r.URL.Path, "ms", time.Since(t0).Milliseconds())
		}
	})
}

func health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if draining.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "draining", "pod": podName})
		return
	}
	if err := db.PingContext(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "degraded", "db_ok": false, "error": err.Error(), "pod": podName})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "ok", "database": "postgres", "db_ok": true, "pod": podName,
		"uptime_s": int(time.Since(started).Seconds()),
	})
}

const jobCols = "id, input, status, COALESCE(result, 'null'::jsonb), error, attempts, submitted_by, processed_by, created_at, finished_at"

func scanJob(sc interface{ Scan(...any) error }) (Job, error) {
	var j Job
	var res []byte
	err := sc.Scan(&j.ID, &j.Input, &j.Status, &res, &j.Error, &j.Attempts, &j.SubmittedBy, &j.ProcessedBy, &j.CreatedAt, &j.FinishedAt)
	j.Result = res
	return j, err
}

func listJobs(w http.ResponseWriter, r *http.Request) {
	rows, err := db.QueryContext(r.Context(), "SELECT "+jobCols+" FROM jobs ORDER BY id DESC LIMIT 50")
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	defer rows.Close()
	jobs := []Job{}
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		jobs = append(jobs, j)
	}
	writeJSON(w, http.StatusOK, jobs)
}

func createJob(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Input string `json:"input"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024)).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	in.Input = strings.TrimSpace(in.Input)
	if in.Input == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "input is required"})
		return
	}
	row := db.QueryRowContext(r.Context(),
		"INSERT INTO jobs (input, submitted_by) VALUES ($1, $2) RETURNING "+jobCols, in.Input, podName)
	j, err := scanJob(row)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusCreated, j)
}

func getJob(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad id"})
		return
	}
	j, err := scanJob(db.QueryRowContext(r.Context(), "SELECT "+jobCols+" FROM jobs WHERE id = $1", id))
	if errors.Is(err, sql.ErrNoRows) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, j)
}

func stats(w http.ResponseWriter, r *http.Request) {
	rows, err := db.QueryContext(r.Context(), "SELECT status, count(*) FROM jobs GROUP BY status")
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	defer rows.Close()
	out := map[string]int{"queued": 0, "running": 0, "done": 0, "failed": 0}
	for rows.Next() {
		var s string
		var n int
		if err := rows.Scan(&s, &n); err == nil {
			out[s] = n
		}
	}
	workers := []string{}
	wr, err := db.QueryContext(r.Context(),
		"SELECT DISTINCT processed_by FROM jobs WHERE processed_by IS NOT NULL AND finished_at > now() - interval '5 minutes'")
	if err == nil {
		defer wr.Close()
		for wr.Next() {
			var p string
			if wr.Scan(&p) == nil {
				workers = append(workers, p)
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"counts": out, "active_workers": workers, "api_pod": podName})
}

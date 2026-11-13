// Project 02 — Bookmark manager: HTMX + Go (single binary) + Turso LibSQL.
//
// The binary embeds templates, static files and SQL migrations, so deployment is
// "copy one file + one env file". It handles SIGTERM/SIGINT gracefully (drains
// in-flight requests) and SIGUSR1 (dumps runtime stats to the log) — used in the
// signals lab of GUIDEBOOK Part C.
package main

import (
	"context"
	"database/sql"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	_ "github.com/tursodatabase/libsql-client-go/libsql"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static/*
var staticFS embed.FS

//go:embed migrations/*.sql
var migrationFS embed.FS

type Bookmark struct {
	ID        int64  `json:"id"`
	URL       string `json:"url"`
	Title     string `json:"title"`
	Tags      string `json:"tags"`
	CreatedAt string `json:"created_at"`
}

func (b Bookmark) TagList() []string {
	var out []string
	for _, t := range strings.Split(b.Tags, ",") {
		if t = strings.TrimSpace(t); t != "" {
			out = append(out, t)
		}
	}
	return out
}

type server struct {
	db        *sql.DB
	tpl       *template.Template
	log       *slog.Logger
	startedAt time.Time
	requests  atomic.Int64
}

func main() {
	seed := flag.Bool("seed", false, "insert sample bookmarks if the table is empty, then continue")
	migrateOnly := flag.Bool("migrate-only", false, "run migrations and exit")
	flag.Parse()

	level := slog.LevelInfo
	if os.Getenv("LOG_LEVEL") == "debug" {
		level = slog.LevelDebug
	}
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level}))

	dsn, err := buildDSN(os.Getenv("TURSO_DATABASE_URL"), os.Getenv("TURSO_AUTH_TOKEN"))
	if err != nil {
		logger.Error("config error", "err", err)
		os.Exit(2)
	}
	db, err := sql.Open("libsql", dsn)
	if err != nil {
		logger.Error("open db", "err", err)
		os.Exit(1)
	}
	db.SetMaxOpenConns(4)
	db.SetConnMaxIdleTime(2 * time.Minute)
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	if err := migrate(ctx, db); err != nil {
		cancel()
		logger.Error("migration failed", "err", err)
		os.Exit(1)
	}
	if *seed {
		if err := seedData(ctx, db); err != nil {
			logger.Warn("seed failed", "err", err)
		}
	}
	cancel()
	if *migrateOnly {
		logger.Info("migrations applied")
		return
	}

	tpl := template.Must(template.New("").ParseFS(templateFS, "templates/*.html"))
	s := &server{db: db, tpl: tpl, log: logger, startedAt: time.Now()}

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:5002"
	}
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           s.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// SIGUSR1: print stats without stopping.
	usr1 := make(chan os.Signal, 1)
	signal.Notify(usr1, syscall.SIGUSR1)
	go func() {
		for range usr1 {
			var m runtime.MemStats
			runtime.ReadMemStats(&m)
			logger.Info("SIGUSR1 stats",
				"pid", os.Getpid(),
				"uptime", time.Since(s.startedAt).Round(time.Second).String(),
				"requests", s.requests.Load(),
				"goroutines", runtime.NumGoroutine(),
				"heap_alloc_mb", m.HeapAlloc/1024/1024)
		}
	}()

	// SIGTERM / SIGINT: graceful shutdown. SIGKILL (-9) cannot be caught.
	stopCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		logger.Info("listening", "addr", addr, "pid", os.Getpid())
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("http server", "err", err)
			os.Exit(1)
		}
	}()

	<-stopCtx.Done()
	logger.Info("shutdown signal received, draining connections (max 10s)")
	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelShutdown()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		logger.Error("forced shutdown", "err", err)
	}
	logger.Info("bye")
}

func buildDSN(rawURL, token string) (string, error) {
	if rawURL == "" {
		return "", errors.New("TURSO_DATABASE_URL is empty")
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("parse TURSO_DATABASE_URL: %w", err)
	}
	if token != "" {
		q := u.Query()
		q.Set("authToken", token)
		u.RawQuery = q.Encode()
	}
	return u.String(), nil
}

func migrate(ctx context.Context, db *sql.DB) error {
	files, err := fs.Glob(migrationFS, "migrations/*.sql")
	if err != nil {
		return err
	}
	for _, f := range files {
		body, err := migrationFS.ReadFile(f)
		if err != nil {
			return err
		}
		for _, stmt := range strings.Split(string(body), ";") {
			if strings.TrimSpace(stmt) == "" {
				continue
			}
			if _, err := db.ExecContext(ctx, stmt); err != nil {
				return fmt.Errorf("%s: %w", f, err)
			}
		}
	}
	return nil
}

func seedData(ctx context.Context, db *sql.DB) error {
	var n int
	if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM bookmarks").Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	samples := []Bookmark{
		{URL: "https://htmx.org/docs/", Title: "htmx documentation", Tags: "frontend,htmx"},
		{URL: "https://go.dev/doc/effective_go", Title: "Effective Go", Tags: "go,backend"},
		{URL: "https://docs.turso.tech", Title: "Turso docs", Tags: "database,sqlite"},
		{URL: "https://man7.org/linux/man-pages/man7/signal.7.html", Title: "signal(7) man page", Tags: "linux,signals"},
	}
	for _, b := range samples {
		if _, err := db.ExecContext(ctx, "INSERT INTO bookmarks(url,title,tags) VALUES (?,?,?)", b.URL, b.Title, b.Tags); err != nil {
			return err
		}
	}
	return nil
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	staticSub, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(http.FS(staticSub))))
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("GET /bookmarks", s.handleList)
	mux.HandleFunc("POST /bookmarks", s.handleCreate)
	mux.HandleFunc("DELETE /bookmarks/{id}", s.handleDelete)
	mux.HandleFunc("GET /api/health", s.handleHealth)
	mux.HandleFunc("GET /api/bookmarks", s.handleAPIList)
	return s.logRequests(mux)
}

func (s *server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		s.requests.Add(1)
		next.ServeHTTP(w, r)
		s.log.Debug("request", "method", r.Method, "path", r.URL.Path, "dur", time.Since(start))
	})
}

func (s *server) query(ctx context.Context, q string) ([]Bookmark, error) {
	sqlText := "SELECT id,url,title,tags,created_at FROM bookmarks"
	var args []any
	if q = strings.TrimSpace(q); q != "" {
		sqlText += " WHERE title LIKE ? OR tags LIKE ? OR url LIKE ?"
		like := "%" + q + "%"
		args = append(args, like, like, like)
	}
	sqlText += " ORDER BY id DESC LIMIT 100"
	rows, err := s.db.QueryContext(ctx, sqlText, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Bookmark
	for rows.Next() {
		var b Bookmark
		if err := rows.Scan(&b.ID, &b.URL, &b.Title, &b.Tags, &b.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (s *server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tpl.ExecuteTemplate(w, name, data); err != nil {
		s.log.Error("template", "name", name, "err", err)
	}
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	items, err := s.query(r.Context(), "")
	if err != nil {
		s.log.Error("list", "err", err)
		http.Error(w, "database error", http.StatusBadGateway)
		return
	}
	s.render(w, "index.html", map[string]any{"Items": items, "Count": len(items)})
}

func (s *server) handleList(w http.ResponseWriter, r *http.Request) {
	items, err := s.query(r.Context(), r.URL.Query().Get("q"))
	if err != nil {
		http.Error(w, "database error", http.StatusBadGateway)
		return
	}
	s.render(w, "list.html", items)
}

func (s *server) handleCreate(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	rawURL := strings.TrimSpace(r.FormValue("url"))
	title := strings.TrimSpace(r.FormValue("title"))
	tags := strings.ToLower(strings.TrimSpace(r.FormValue("tags")))
	u, err := url.Parse(rawURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		w.Header().Set("HX-Retarget", "#form-error")
		w.Header().Set("HX-Reswap", "innerHTML")
		w.WriteHeader(http.StatusUnprocessableEntity)
		fmt.Fprint(w, "Please enter an absolute http(s) URL.")
		return
	}
	if title == "" {
		title = u.Host
	}
	var b Bookmark
	err = s.db.QueryRowContext(r.Context(),
		"INSERT INTO bookmarks(url,title,tags) VALUES (?,?,?) RETURNING id,url,title,tags,created_at",
		u.String(), title, tags).Scan(&b.ID, &b.URL, &b.Title, &b.Tags, &b.CreatedAt)
	if err != nil {
		s.log.Error("insert", "err", err)
		http.Error(w, "database error", http.StatusBadGateway)
		return
	}
	w.Header().Set("HX-Trigger", "bookmark-added")
	s.render(w, "row.html", b)
}

func (s *server) handleDelete(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	if _, err := s.db.ExecContext(r.Context(), "DELETE FROM bookmarks WHERE id = ?", id); err != nil {
		http.Error(w, "database error", http.StatusBadGateway)
		return
	}
	w.WriteHeader(http.StatusOK) // empty body + hx-swap="outerHTML" removes the row
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	dbErr := s.db.PingContext(ctx)
	if dbErr == nil {
		var one int
		dbErr = s.db.QueryRowContext(ctx, "SELECT 1").Scan(&one)
	}
	resp := map[string]any{
		"status":   "ok",
		"database": "turso-libsql",
		"db_ok":    dbErr == nil,
		"pid":      os.Getpid(),
		"uptime_s": int(time.Since(s.startedAt).Seconds()),
		"requests": s.requests.Load(),
	}
	code := http.StatusOK
	if dbErr != nil {
		resp["status"] = "degraded"
		resp["error"] = dbErr.Error()
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, resp)
}

func (s *server) handleAPIList(w http.ResponseWriter, r *http.Request) {
	items, err := s.query(r.Context(), r.URL.Query().Get("q"))
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	if items == nil {
		items = []Bookmark{}
	}
	writeJSON(w, http.StatusOK, items)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

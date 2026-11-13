# Project 07 — Snippet Bin · GUIDEBOOK

**Stack:** Vue 3 (CDN global build, no bundler) · Ruby 3.2 Sinatra + Puma · Upstash Redis (TLS) · Caddy
**Linux focus:** the Unix text-processing toolkit — `grep`, `awk`, `sed`, `cut`, `sort`, `uniq`, `head`/`tail`, `wc`, `tee`, `xargs`; pipes `|`; file descriptors; stdout/stderr redirection; buffering
**Script:** `scripts/log_analyzer.sh` (+ `sample-logs/access.sample.log` for offline practice)
**RAM budget:** Puma single mode, 4 threads ≈ 60–80 MB

---

## Part A — Concepts to Learn First

### A1. The Unix philosophy
"Write programs that do one thing well, that work together, and that handle **text streams**." A log file is just lines of text; small tools chained with pipes answer almost any question about it — no Python, no ELK stack needed on a 1 GB box.

### A2. File descriptors & redirection
Every process starts with three open FDs: **0 stdin**, **1 stdout**, **2 stderr**.

| Syntax | Meaning |
|--------|---------|
| `cmd > f` | stdout → file (truncate) |
| `cmd >> f` | stdout → file (append) |
| `cmd 2> err.log` | stderr → file |
| `cmd > out 2>&1` | stdout → out, **then** stderr → wherever stdout points now (order matters!) |
| `cmd 2>&1 > out` | stderr → terminal (old stdout), stdout → out |
| `cmd &> all.log` | bash shortcut for both |
| `cmd < f` | stdin from file |
| `cmd 2>/dev/null` | discard errors |
| `cmd | tee f` | stdout to screen **and** file |
| `cmd |& grep x` | pipe stdout+stderr |
| `<(cmd)` | process substitution: output as a temporary file path |

`log_analyzer.sh` prints the **report to stdout** and **diagnostics to stderr**, so `log_analyzer.sh > report.txt 2> errors.txt` separates them cleanly.

### A3. What a pipe really is
`a | b` → the kernel creates an in-memory buffer (64 KB). `a` writes into it, `b` reads from it, **both run concurrently**. If `b` exits early (`head`), `a` receives **SIGPIPE** and stops. Exit status of a pipeline = last command, unless `set -o pipefail`.

**Buffering trap:** when stdout is not a terminal, many tools switch from *line* buffering to *block* buffering (4–64 KB). `tail -f log | grep 500 | awk …` shows nothing for a long time → use `grep --line-buffered`, `awk '{…; fflush()}'`, or `stdbuf -oL`. (The `--live` mode demonstrates this.)

### A4. The toolkit, one line each
| Tool | Mental model | Example on our log |
|------|--------------|--------------------|
| `grep -E` | keep lines matching a regex | `grep -E ' 5[0-9]{2} ' access.log` |
| `grep -v` / `-c` / `-o` | invert / count / only the match | `grep -oE 'GET [^ ]+' access.log` |
| `cut -d' ' -f2` | pick columns by a **single-char** delimiter | IPs |
| `awk '{print $5}'` | columns split on **runs of whitespace**, plus logic & math | `awk '$6 > 1000' access.log` (slow requests) |
| `sed -E 's#a#b#'` | stream edit: substitute/delete lines | normalise IDs to `:id` |
| `sort` / `sort -n` / `-k3,3n` / `-t=` | order lines; numeric; by key; custom separator | |
| `uniq -c` | count **adjacent** duplicates → always `sort` first! | |
| `sort | uniq -c | sort -rn | head` | **the** frequency-table idiom | top IPs |
| `wc -l` | count lines | total requests |
| `head -n` / `tail -n` / `tail -F` | first/last lines; follow across rotation | |
| `xargs` | turn lines into arguments | `… | xargs -n1 dig +short -x` |
| `zcat` / `zgrep` | read rotated `.gz` logs | |

### A5. awk in 5 minutes
`awk 'PATTERN { ACTION }' file` — for every line: split into `$1..$NF` (`$0` whole line, `NF` field count, `NR` line number), if PATTERN is true run ACTION. `BEGIN{}` runs before input, `END{}` after. Variables are created on use; arrays are associative (`count[$2]++`). Pass shell values safely with `-v name="$var"` (never by splicing `$var` into the program text).

### A6. sed in 3 minutes
`sed -E 's/regex/replacement/g'` substitutes; `-E` enables extended regex (`+ ? {n} ()` without backslashes). Any delimiter works: `s#/api/x#/api/:id#` avoids escaping `/`. `sed -n '5,10p'` prints lines 5–10. `sed -i.bak` edits files in place with a backup.

### A7. Regular-expression essentials
`^` start, `$` end, `.` any char, `[0-9]` class, `{3}` exactly 3, `+` one or more, `*` zero or more, `?` optional, `(a|b)` alternation, `[^ ]+` "a run of non-spaces" (the most useful log regex).

### A8. Redis & Upstash
In-memory key-value store. We use a **hash** per snippet (`HSET snip:<id> title … content …`), **EXPIRE** for auto-deletion (TTL), a capped **list** (`LPUSH` + `LTRIM 0 49`) for "recent", and `INCR` counters — all inside `MULTI` so they apply atomically. Upstash speaks the Redis protocol over **TLS** (`rediss://`), so `redis-cli --tls -u "$REDIS_URL"` works from the box.

### A9. Puma & Bundler
Puma = Ruby app server; `workers 0` = single process (no fork) with 2–4 threads → minimal RAM. **Bundler** installs gems listed in `Gemfile` into `vendor/bundle` (deployment mode) so the system Ruby stays clean; `bundle exec` loads exactly those versions.

### A10. Bash concepts in `log_analyzer.sh`
Arrays of files (`FILES+=()`), `shopt -s nullglob` (unmatched globs vanish instead of staying literal), `mktemp` + `trap 'rm -f' EXIT` (temp file always cleaned up), functions as pipeline stages (`emit | awk … > tmp`), `[[ ",$LIST," == *",x,"* ]]` (membership test), `printf '%.0s=' $(seq …)` (repeat a character), heredoc-free usage via `sed -n '2,23p' "$0"`.

---

## Part B — Architecture & Request Flow

```
 Browser (Vue 3 from unpkg, hash routing #/s/<id>)
 https://<IP>.sslip.io
     │
     ▼
 ┌──────────────┐ /api/* ┌────────────────────────────────────────────┐ rediss:// (TLS 6379) ┌─────────────────────┐
 │ Caddy :443   │──────▶ │ Puma (single mode, 2–4 threads) User=snippetbin│────────────────────▶ │ Upstash Redis       │
 │ / → public/  │ :5007  │  Rack middleware PlainAccessLog ───┐       │  HSET/EXPIRE/LPUSH   │ snip:<id> (hash+TTL)│
 │ JSON log ────┼─┐      │  Sinatra routes /api/...           │       │                      │ snips:recent (list) │
 └──────────────┘ │      └────────────────────────────────────┼───────┘                      └─────────────────────┘
                  ▼                                           ▼
     /var/log/caddy/snippetbin.access.log      /var/log/snippetbin/access.log   (plain text, one line per request)
                                                              │
                                    log_analyzer.sh: emit → awk filter → { sort | uniq -c | sort -rn | head } → report
```

---

## Part C — Step-by-Step Manual Deployment Lab

### C1. Practise the pipelines offline first (works on your laptop too)
```bash
cd ~/linux-devops-13-projects/project-07-snippet-bin
L=sample-logs/access.sample.log
head -3 $L; wc -l $L
awk '{print $5}' $L | sort | uniq -c | sort -rn                  # status histogram
grep -c ' 500 ' $L                                                 # how many 500s?
awk '$6 > 1000 {print $1, $4, $6"ms"}' $L | head                  # slow requests
cut -d' ' -f2 $L | sort | uniq -c | sort -rn | head -5            # top IPs
awk '$5==404 {print $2}' $L | sort | uniq -c | sort -rn | head -3  # scanners
sed -E 's#/api/snippets/[A-Za-z0-9]{8}#/api/snippets/:id#' $L | awk '{print $4}' | sort | uniq -c | sort -rn
cut -c1-13 $L | uniq -c                                            # requests per hour
awk '{s[$4]+=$6; n[$4]++} END {for (p in s) printf "%8.1f %s\n", s[p]/n[p], p}' $L | sort -rn | head -3
grep -v -E '^[0-9]{4}-' $L                                         # malformed lines
scripts/log_analyzer.sh -f $L > /tmp/report.txt 2> /tmp/analyzer.err; cat /tmp/analyzer.err
scripts/log_analyzer.sh -f $L --status '^5' --sections summary,paths,errors
scripts/log_analyzer.sh -f $L -s 2025-01-31T10 -u 2025-01-31T10 --sections summary
```

### C2. Switch back to Caddy, install Ruby
```bash
sudo systemctl disable --now nginx php8.3-fpm 2>/dev/null || true
sudo systemctl enable --now caddy
sudo apt-get install -y ruby-full build-essential redis-tools bundler
ruby -v && which bundle            # /usr/bin/bundle — the path used in ExecStart
```

### C3. User, dirs, code, gems
```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group snippetbin
sudo install -d -m 0755 -o root -g root /opt/snippetbin
sudo install -d -m 0750 -o root -g snippetbin /etc/snippetbin
sudo install -d -m 2750 -o snippetbin -g snippetbin /var/log/snippetbin
sudo cp -r app public /opt/snippetbin/
cd /opt/snippetbin/app
sudo bundle config set --local deployment false
sudo bundle config set --local path vendor/bundle
sudo bundle install --jobs 1        # creates Gemfile.lock + vendor/bundle (needs swap for native gems)
sudo chown -R root:snippetbin /opt/snippetbin && sudo chmod -R u=rwX,g=rX,o=rX /opt/snippetbin
```

### C4. Config + Redis connectivity
```bash
sudo cp ~/linux-devops-13-projects/project-07-snippet-bin/.env.example /etc/snippetbin/snippetbin.env
sudo nano /etc/snippetbin/snippetbin.env
sudo chown root:snippetbin /etc/snippetbin/snippetbin.env && sudo chmod 640 /etc/snippetbin/snippetbin.env
REDIS_URL=$(sudo grep ^REDIS_URL /etc/snippetbin/snippetbin.env | cut -d= -f2-)
redis-cli --tls -u "$REDIS_URL" PING
```

### C5. Service + Caddy
```bash
sudo cp ~/linux-devops-13-projects/project-07-snippet-bin/deploy/snippetbin.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now snippetbin
journalctl -u snippetbin -n 20 --no-pager
curl -s http://127.0.0.1:5007/api/health | jq
sudo cp ~/linux-devops-13-projects/project-07-snippet-bin/deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

### C6. Generate real traffic and analyse it
```bash
IP=$(curl -s https://checkip.amazonaws.com); B=https://$IP.sslip.io
for i in $(seq 1 30); do
  curl -s -o /dev/null -X POST $B/api/snippets -H 'Content-Type: application/json' \
       -d "{\"title\":\"t$i\",\"lang\":\"bash\",\"content\":\"echo $i\"}"
  curl -s -o /dev/null $B/api/snippets
done
for i in $(seq 1 5); do curl -s -o /dev/null $B/api/lab/error; curl -s -o /dev/null $B/api/lab/slow; done
for p in .env wp-login.php admin; do curl -s -o /dev/null $B/api/$p; done
sudo install -m 0755 ~/linux-devops-13-projects/project-07-snippet-bin/scripts/log_analyzer.sh /usr/local/bin/
sudo log_analyzer.sh
sudo log_analyzer.sh --live          # in another terminal: curl $B/api/lab/error
# Caddy's JSON log with jq, for comparison:
sudo tail -n 200 /var/log/caddy/snippetbin.access.log | jq -r '.status' | sort | uniq -c
```

### C7. Rotate the app log (it's not journald)
```bash
sudo tee /etc/logrotate.d/snippetbin >/dev/null <<'EOF'
/var/log/snippetbin/access.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
sudo logrotate -d /etc/logrotate.d/snippetbin     # dry run
sudo logrotate -f /etc/logrotate.d/snippetbin && ls -l /var/log/snippetbin/
sudo log_analyzer.sh -f /var/log/snippetbin/access.log.1 --sections summary
```

---

## Part D — Break-Fix Drills

### Drill 1 — `uniq -c` gives wrong counts
**Break:** `awk '{print $5}' $L | uniq -c | head`.
**Symptom:** the same status code appears many times with small counts.
**Diagnose:** `uniq` only collapses **adjacent** duplicates.
**Fix:** `awk '{print $5}' $L | sort | uniq -c | sort -rn`. **Lesson:** always `sort` before `uniq`.

### Drill 2 — "My errors vanished" / "my log is full of errors" (redirection order)
**Break:** `scripts/log_analyzer.sh -f /nope 2>&1 > /tmp/r.txt` and then `scripts/log_analyzer.sh -f /nope > /tmp/r.txt 2>&1`.
**Symptom:** first form prints the error on screen and the file is empty; second puts the error *inside* the report file.
**Diagnose:** redirections are processed left to right; `2>&1` copies *where stdout points at that moment*.
**Fix:** for scripts used by cron: `cmd >> report.log 2>> error.log`. **Lesson:** reason about FDs as pointers.

### Drill 3 — App returns 503 for everything; Redis "SSL_connect" / "Connection refused"
**Break:** change `rediss://` to `redis://` in the env file and restart.
**Symptom:** `/api/health` → 503 `redis unavailable`; live analyzer shows a wall of 503s.
**Diagnose:**
```bash
sudo log_analyzer.sh -s "$(date -u +%Y-%m-%dT%H)" --sections status
journalctl -u snippetbin -p warning -n 20 --no-pager | grep -iE 'redis|ssl|refused'
redis-cli -u "redis://…" PING   # fails / hangs ;  redis-cli --tls -u "rediss://…" PING → PONG
```
**Fix:** restore `rediss://` (TLS), restart. **Lesson:** Upstash requires TLS; and logs let you pinpoint *when* the error rate started (the busiest-minute and 5xx sections).

**Bonus — `tail -f | grep | awk` shows nothing:** remove `--line-buffered` and `fflush()` from the `--live` pipeline, generate a few errors, and observe the delay. That's block buffering.

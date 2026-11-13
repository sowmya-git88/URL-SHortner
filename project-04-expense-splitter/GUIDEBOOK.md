# Project 04 — Expense Splitter · GUIDEBOOK

**Stack:** Vanilla JS · Python FastAPI + Uvicorn · Neon serverless Postgres · **Caddy (deep-dive)**
**Linux focus:** reverse-proxy theory, Caddyfile structure, `/api/*` vs `/` routing, `handle` vs `handle_path`, automatic HTTPS on `<IP>.sslip.io`, ACME, certificate storage, safe reloads
**Script:** `scripts/deploy_fastapi.sh` (repeatable deploy with automatic rollback)
**RAM budget:** Uvicorn 1 worker ≈ 60–80 MB

---

## Part A — Concepts to Learn First

### A1. What a reverse proxy actually does
A **forward** proxy acts for clients (corporate web filter). A **reverse** proxy acts for servers: clients think Caddy *is* the website. Caddy:
1. terminates TLS (decrypts HTTPS once, at the edge),
2. picks a backend based on host/path (**routing**),
3. opens a *new* TCP connection to `127.0.0.1:5004`, forwards the request and adds headers: `X-Forwarded-For` (client IP), `X-Forwarded-Proto` (https), `X-Forwarded-Host`,
4. streams the response back, compresses it (`encode`), adds security headers.

So the app never handles TLS, never binds a public port, never runs as root.

### A2. Caddyfile anatomy
```
{ global options }            ← optional, must be first
(snippet) { ... }             ← reusable block, used with: import snippet
site-address {                ← one or more addresses: example.com, http://1.2.3.4, :8080
    directive args {          ← e.g. reverse_proxy, file_server, header, log
        subdirective
    }
}
```
* **Site address decides TLS:** a hostname like `1.2.3.4.sslip.io` → automatic HTTPS. Prefix `http://` → plain HTTP only, no certificate attempt.
* `{$EC2_IP}` → environment variable substituted **when the config is parsed** (from `/etc/caddy/caddy.env` via our systemd drop-in). `{remote_host}` (no `$`) → *runtime* placeholder evaluated per request.

### A3. Directive order & `handle` blocks (the #1 source of confusion)
Caddy sorts directives in a fixed **directive order**, not in the order you write them. To get predictable, mutually-exclusive routing, wrap routes in **`handle`** blocks: the **first matching `handle` wins** (most specific matcher first is sorted automatically; a bare `handle {}` is the fallback).

| Directive | Path seen by backend for request `/api/groups` |
|-----------|-----------------------------------------------|
| `handle /api/* { reverse_proxy … }` | `/api/groups` ✅ (our FastAPI routes include `/api`) |
| `handle_path /api/* { reverse_proxy … }` | `/groups` (prefix **stripped**) → FastAPI 404 ❌ |

Rule: use `handle_path` only when the backend does **not** know about the prefix.

**Matcher gotcha:** `/api*` also matches `/apiary`; `/api/*` does **not** match `/api` itself. Path matchers are exact unless you use `*`.

### A4. SPA + static files
`root * /opt/expense/web` sets the document root; `try_files {path} /index.html` returns `index.html` for unknown paths (client-side routing); `file_server` serves files. The `caddy` user must be able to *traverse* every parent directory (`x`) and *read* the files (`r`).

### A5. Automatic HTTPS, step by step
1. Caddy loads the config, sees `1.2.3.4.sslip.io`, has no certificate in storage.
2. It creates an ACME account with Let's Encrypt (and ZeroSSL as fallback).
3. **Challenge:** HTTP-01 (LE fetches `http://1.2.3.4.sslip.io/.well-known/acme-challenge/<token>` on **port 80**) or TLS-ALPN-01 (on **port 443**). That's why 80/443 must be open in the SG and `ufw`.
4. LE resolves `1.2.3.4.sslip.io` via sslip.io's DNS → your IP → challenge succeeds → certificate issued (90-day validity).
5. Stored in `/var/lib/caddy/.local/share/caddy/certificates/…`; renewed automatically around 1/3 of lifetime remaining.
6. HTTP on that hostname is auto-redirected to HTTPS.

Bare IP → `http://` block only (we don't request IP certificates). Rate limits exist per registered domain; if issuance is throttled, Caddy retries and may fall back to ZeroSSL. For a lab you can temporarily add `tls internal` to a site (self-signed, browser warning).

### A6. Reloads without downtime
`systemctl reload caddy` → `caddy reload` → POSTs the new config to the **admin API** (`localhost:2019`). Caddy builds the new config, and only if it is valid swaps it in atomically; old connections finish gracefully. A **broken** config is rejected and the old one keeps running. Still: always `caddy validate` first.

### A7. FastAPI, ASGI and Uvicorn
FastAPI is an ASGI framework; **Uvicorn** is the ASGI server. `--proxy-headers --forwarded-allow-ips 127.0.0.1` tells Uvicorn to trust `X-Forwarded-*` only from Caddy, so `request.client.host` becomes the real visitor IP. One worker is enough on 1 vCPU.

### A8. Neon serverless Postgres quirks
* Compute **auto-suspends** after idle time; first query after that takes a moment (cold start) and old connections are dead. We use `psycopg_pool` with `check=ConnectionPool.check_connection` so a dead connection is replaced instead of causing a 500.
* Use the **pooled** host (`-pooler` in the hostname) and `sslmode=require`.
* Money is stored as **integer cents** (`BIGINT`) — floats can't represent 0.10 exactly.

### A9. Bash concepts in `deploy_fastapi.sh`
`trap rollback ERR` + `set -E` (errtrace) for automatic rollback; snapshot via `cp -a` (preserves owner/mode/timestamps); `rsync -a --delete` (mirror, remove stale files); content hash (`sha256sum`) to skip unchanged `pip install`; `systemd-run --uid --wait --pipe` to run migrations as the app user with the same env file; retry loop with `for (( i=1; i<=N; i++ ))`; `stat -c '%a %U:%G'` permission assertions.

---

## Part B — Architecture & Request Flow

```
                         ┌────────────────────────── Caddy (:80, :443) ──────────────────────────────────┐
 Browser ──HTTPS──▶      │ site: {$EC2_IP}.sslip.io   (cert: Let's Encrypt, auto-renew)                  │
 https://<IP>.sslip.io   │ site: http://{$EC2_IP}     (plain HTTP)                                        │
                         │                                                                                │
                         │  handle /api/*  ──────────────▶ reverse_proxy 127.0.0.1:5004 (path unchanged)  │
                         │  handle (fallback) ───────────▶ file_server /opt/expense/web + try_files SPA   │
                         │  header: HSTS, nosniff, CSP     handle_errors 502/503/504 → friendly message    │
                         └──────────────────────────────────────┬─────────────────────────────────────────┘
                                                                │ X-Forwarded-For / -Proto
                                                                ▼
                                       ┌─────────────────────────────────────────┐
                                       │ uvicorn main:app  (User=expense)        │
                                       │ FastAPI routes /api/groups, /api/health │
                                       │ psycopg_pool (min 1, max 4, check conn) │
                                       └──────────────────────┬──────────────────┘
                                                              │ TLS (sslmode=require), port 5432
                                                              ▼
                                       ┌─────────────────────────────────────────┐
                                       │ Neon Postgres (pooler endpoint)         │
                                       │ groups · members · expenses · shares    │
                                       └─────────────────────────────────────────┘
```

---

## Part C — Step-by-Step Manual Deployment Lab

### C1. Neon
Create a project → database `expense` → copy the **pooled** connection string.

### C2. User & directories
```bash
sudo systemctl disable --now habits 2>/dev/null || true
sudo apt-get install -y rsync python3-venv
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group expense
sudo install -d -m 0755 -o root -g expense /opt/expense
sudo install -d -m 0750 -o root -g expense /etc/expense
sudo cp ~/linux-devops-13-projects/project-04-expense-splitter/.env.example /etc/expense/expense.env
sudo nano /etc/expense/expense.env                       # paste DATABASE_URL
sudo chown root:expense /etc/expense/expense.env && sudo chmod 640 /etc/expense/expense.env
```

### C3. Deploy manually once (understand each step)
```bash
cd ~/linux-devops-13-projects/project-04-expense-splitter
sudo rsync -a api/ /opt/expense/api/ && sudo rsync -a web/ /opt/expense/web/
sudo python3 -m venv /opt/expense/venv
sudo /opt/expense/venv/bin/pip install --no-cache-dir -r /opt/expense/api/requirements.txt
sudo systemd-run --wait --pipe --uid=expense --gid=expense \
     -p EnvironmentFile=/etc/expense/expense.env -p WorkingDirectory=/opt/expense/api \
     /opt/expense/venv/bin/python migrate.py
sudo cp deploy/expense.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now expense
curl -s http://127.0.0.1:5004/api/health | jq
```

### C4. …then automate it
```bash
sudo scripts/deploy_fastapi.sh --dry-run
sudo scripts/deploy_fastapi.sh --with-caddy
```

### C5. Caddy deep-dive exercises
```bash
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile
sudo env $(sudo cat /etc/caddy/caddy.env) caddy fmt --diff /etc/caddy/Caddyfile      # formatting check
sudo env $(sudo cat /etc/caddy/caddy.env) caddy validate --config /etc/caddy/Caddyfile
sudo env $(sudo cat /etc/caddy/caddy.env) caddy adapt --config /etc/caddy/Caddyfile --pretty | less   # see the JSON Caddy really runs
sudo systemctl reload caddy
sudo journalctl -u caddy -f        # watch "obtaining certificate" → "certificate obtained successfully"
sudo ls -R /var/lib/caddy/.local/share/caddy/certificates/ | head
curl -s localhost:2019/config/ | jq '.apps.http.servers | keys'     # admin API (localhost only)
```

### C6. Verify routing & TLS
```bash
IP=$(curl -s https://checkip.amazonaws.com)
curl -sI http://$IP.sslip.io/            | head -3      # 308 redirect → https
curl -sI https://$IP.sslip.io/           | grep -iE 'HTTP/|strict|content-type'
curl -s  https://$IP.sslip.io/api/health | jq
curl -s  https://$IP.sslip.io/api/groups | jq '.[0]'
curl -s  https://$IP.sslip.io/some/spa/route | head -3  # index.html (try_files)
echo | openssl s_client -connect $IP.sslip.io:443 -servername $IP.sslip.io 2>/dev/null | openssl x509 -noout -issuer -dates
sudo tail -n 3 /var/log/caddy/expense.access.log | jq '{status, uri: .request.uri, ms: (.duration*1000)}'
```

---

## Part D — Break-Fix Drills

### Drill 1 — Every API call returns 404 (the `handle_path` trap)
**Break:** in the Caddyfile change `handle /api/*` to `handle_path /api/*`, reload.
**Symptom:** UI loads, `/api/health` → `{"detail":"Not Found"}` (that's FastAPI's 404, not Caddy's!).
**Diagnose:** `journalctl -u expense -n 5` shows `GET /health 404` — the prefix was stripped.
**Fix:** revert to `handle`. **Lesson:** read the backend log to see the path it actually received.

### Drill 2 — Certificate is never issued
**Break:** `sudo ufw delete allow 80/tcp` and delete the cert storage: `sudo systemctl stop caddy; sudo rm -rf /var/lib/caddy/.local/share/caddy/certificates; sudo systemctl start caddy`.
**Symptom:** browser `ERR_SSL_PROTOCOL_ERROR`; logs: `challenge failed`, `Timeout during connect (likely firewall problem)`.
**Diagnose:** `sudo journalctl -u caddy -g 'challenge|error' -n 20`; from your laptop `curl -v http://<IP>.sslip.io/.well-known/acme-challenge/x` (times out).
**Fix:** `sudo ufw allow 80/tcp` (and check the SG), `sudo systemctl restart caddy`. **Lesson:** HTTP-01 needs port 80 even if you only serve HTTPS. Don't loop restarts — Let's Encrypt has failed-validation rate limits.

### Drill 3 — Deploy breaks prod → automatic rollback
**Break:** add a syntax error to `api/main.py` (e.g. delete a closing parenthesis) and run `sudo scripts/deploy_fastapi.sh`.
**Symptom:** health check fails 20×, script prints `rolling back`, then `rollback healthy`.
**Diagnose:** `ls /opt/expense/` → `api`, `api.prev`, `api.failed`; `journalctl -u expense -n 30 | grep SyntaxError`.
**Fix:** fix the code, redeploy. **Lesson:** a deploy script must be able to undo itself. (Bonus: with `--skip-migrate`, why are *schema* rollbacks harder than code rollbacks?)

**Bonus — 502 during Neon cold start:** after a long idle period, the first request may be slow. `lb_try_duration 5s` in the Caddyfile plus the pool's connection check hide this from users. Turn `lb_try_duration` off and compare.

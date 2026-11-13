# Project 06 — Support Tickets · GUIDEBOOK

**Stack:** Preact + htm (ES modules, no build) · PHP 8.3 + PHP-FPM · Aiven Free MySQL (TLS) · **Nginx + Certbot** · DuckDNS
**Linux focus:** Nginx architecture, server blocks & `default_server`, FastCGI, PHP-FPM pools, **Unix domain sockets** and their permissions, Let's Encrypt via Certbot, renewal timers, DuckDNS dynamic DNS
**Script:** `scripts/nginx_vhost.sh` (+ helper `scripts/duckdns_update.sh`)
**RAM budget:** Nginx ≈ 10 MB · FPM `ondemand` master ≈ 15 MB + ≈ 25 MB per active worker (max 4)

---

## Part A — Concepts to Learn First

### A1. Switching the edge proxy from Caddy to Nginx
Only one process may bind :80/:443. For this project: `sudo systemctl disable --now caddy`, then install Nginx. (Switch back for Project 07 with the reverse.)

### A2. Nginx architecture
* **Master process** (root): reads config, binds ports 80/443, manages workers.
* **Worker processes** (user `www-data`): event-driven, each handles thousands of connections.
* Config tree: `/etc/nginx/nginx.conf` → `http { include /etc/nginx/conf.d/*.conf; include /etc/nginx/sites-enabled/*; }`.
* Debian convention: write sites in **`sites-available/`**, enable with a **symlink** in **`sites-enabled/`**, disable by removing the symlink — the file stays.
* `nginx -t` validates the full config tree. `systemctl reload nginx` = SIGHUP to the master → new workers with new config, old workers finish their requests (graceful).

### A3. How Nginx picks a `server` block
1. Match the **listen** address/port.
2. Among those, match the request's **`Host` header** against `server_name` (exact → leading wildcard → trailing wildcard → regex).
3. Nothing matches → the **`default_server`** for that port (or the first one defined).

Our design: `server_name _; default_server` catches the **raw IP** (Host = `1.2.3.4`); the named block handles `myapp.duckdns.org` and `1.2.3.4.sslip.io` and is the one Certbot upgrades to HTTPS.

### A4. `location` matching order
`=` exact → `^~` prefix (stop) → regex `~`/`~*` in file order → longest plain prefix. That's why `location = /api/login` (rate-limited) wins over `location /api/`, and `location ~ \.php$ { return 404; }` prevents downloading PHP source.

### A5. FastCGI & PHP-FPM
Nginx cannot execute PHP. It speaks the **FastCGI** protocol to **PHP-FPM** (FastCGI Process Manager), which keeps a pool of PHP workers warm. Nginx sends variables (`SCRIPT_FILENAME`, `REQUEST_METHOD`, `QUERY_STRING`, `HTTPS`…, from `fastcgi_params`) plus the body; FPM runs the script and returns the response.

**Front-controller pattern:** we *hard-code* `SCRIPT_FILENAME /opt/tickets/api/index.php`, so a request can never make FPM execute an arbitrary file path (the classic `cgi.fix_pathinfo` exploit class).

### A6. FPM pools
`/etc/php/8.3/fpm/pool.d/*.conf` — each `[pool]` has its own **user**, socket, process manager and PHP limits. One pool per app = isolation (app A's code can't read app B's files). Process managers:
| `pm =` | Behaviour | Good for |
|--------|-----------|----------|
| `static` | always N workers | high traffic, lots of RAM |
| `dynamic` | between min/max spare | general |
| **`ondemand`** | 0 workers until a request arrives; die after idle timeout | **1 GB box** |

We also disable the default `www` pool to save RAM.

### A7. Unix domain sockets vs TCP
A Unix socket is a **file** (`srw-rw---- www-data www-data /run/php/php8.3-fpm-tickets.sock`) used for IPC on the same host. Benefits: no TCP handshake/port, slightly faster, and **access is controlled by file permissions** — only processes that can write to the socket file (Nginx workers as `www-data`) can talk to FPM. `/run` is a tmpfs (RAM), recreated at boot. Inspect with `ss -xlp`.
Common failure: wrong `listen.owner/group/mode` → Nginx log: `connect() to unix:/run/php/... failed (13: Permission denied)` → **502**.

### A8. Let's Encrypt with Certbot
`certbot --nginx -d a -d b`:
1. Temporarily injects a `location /.well-known/acme-challenge/` into the matching server block.
2. Let's Encrypt fetches the token over **HTTP :80** (HTTP-01).
3. Certificate + key saved under `/etc/letsencrypt/live/<name>/` (`fullchain.pem`, `privkey.pem` → symlinks into `archive/`).
4. Edits the server block: `listen 443 ssl`, `ssl_certificate …`, and with `--redirect` a 301 from HTTP.
5. Renewal: `certbot.timer` (systemd) runs twice daily; `certbot renew --dry-run` tests it.

### A9. DuckDNS
Free dynamic DNS: `myapp.duckdns.org` → your IP, updated by an HTTPS GET with your token. EC2's public IP changes on stop/start, so `duckdns_update.sh` runs from **cron** every 5 minutes. We put **both** names (DuckDNS and sslip.io) on one certificate.

### A10. Sessions & cookies behind HTTP vs HTTPS
The agent login uses a PHP session cookie with `HttpOnly`, `SameSite=Lax`, and `Secure` **only when the request came over HTTPS** (`$_SERVER['HTTPS']`, set by Nginx's `fastcgi_params` on TLS). A `Secure` cookie would never be sent back over `http://<raw-IP>`, so login would silently fail there.

### A11. Aiven MySQL specifics
TLS is mandatory → `PDO::MYSQL_ATTR_SSL_CA` = the CA file you download from the console. Aiven enforces `sql_require_primary_key` (all our tables have one) and its default `sql_mode` includes ANSI-style quoting — use **single quotes** for string literals in SQL.

### A12. Bash concepts in `nginx_vhost.sh`
`envsubst '${A} ${B}'` (restricted substitution so Nginx's `$uri` survives), backup/restore with `trap … ERR`, `ln -sfn` (atomic symlink replace), `test -S` (is socket), `sudo -u www-data test -w` (check permissions *as the worker user*), arrays for safe argument building (`args+=(-d "$d")`, `"${args[@]}"`).

---

## Part B — Architecture & Request Flow

```
 Browser
 https://myapp.duckdns.org  /  https://<IP>.sslip.io  /  http://<IP>
     │  DNS: DuckDNS A record (updated by cron) / sslip.io
     ▼
 ┌──────────────────────────── Nginx master (root) · workers (www-data) ─────────────────────────────┐
 │ :80 default_server  server_name _                → raw IP, plain HTTP                              │
 │ :443 ssl  server_name myapp.duckdns.org <IP>.sslip.io  (certs: /etc/letsencrypt/live/…)           │
 │   location /          → try_files → /opt/tickets/public/index.html (Preact via esm.sh)             │
 │   location = /api/login  → limit_req 10r/m ┐                                                       │
 │   location /api/      ─────────────────────┴─▶ fastcgi_pass unix:/run/php/php8.3-fpm-tickets.sock  │
 └──────────────────────────────────────────────────────────────┬─────────────────────────────────────┘
                                         srw-rw---- www-data    │ FastCGI over Unix socket
                                                                ▼
                       ┌────────────────────── PHP-FPM pool [tickets] (user tickets) ─────────────┐
                       │ pm=ondemand max_children=4 · clear_env · open_basedir · memory_limit 64M  │
                       │ SCRIPT_FILENAME=/opt/tickets/api/index.php (front controller)             │
                       │ sessions: /var/lib/php/sessions-tickets   logs: /var/log/tickets/         │
                       └──────────────────────────────────┬────────────────────────────────────────┘
                                                          │ MySQL protocol + TLS (CA: /etc/tickets/aiven-ca.pem)
                                                          ▼
                                         ┌──────────────────────────────────┐
                                         │ Aiven Free MySQL                 │
                                         │ agents · tickets · comments      │
                                         └──────────────────────────────────┘
 cron */5 → duckdns_update.sh → https://www.duckdns.org/update      certbot.timer → certbot renew
```

---

## Part C — Step-by-Step Manual Deployment Lab

### C1. Accounts
* **Aiven:** create a free MySQL service → note host, port, user, password → download **CA certificate**.
* **DuckDNS:** sign in → create subdomain (e.g. `devops-tickets`) → copy the **token**.

### C2. Swap edge proxy, install packages
```bash
sudo systemctl disable --now flashcards caddy 2>/dev/null || true
sudo apt-get install -y nginx php8.3-fpm php8.3-mysql php8.3-mbstring php8.3-cli \
     certbot python3-certbot-nginx gettext-base
systemctl status nginx php8.3-fpm --no-pager | grep -E 'Loaded|Active'
```

### C3. User, directories, code
```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group tickets
sudo install -d -m 0755 -o root -g root    /opt/tickets
sudo install -d -m 0750 -o root -g tickets /etc/tickets
sudo install -d -m 0750 -o tickets -g tickets /var/log/tickets /var/lib/php/sessions-tickets
cd ~/linux-devops-13-projects/project-06-support-tickets
sudo cp -r public api db /opt/tickets/
sudo chown -R root:root /opt/tickets/public && sudo chmod -R u=rwX,go=rX /opt/tickets/public     # www-data reads
sudo chown -R root:tickets /opt/tickets/api /opt/tickets/db && sudo chmod -R u=rwX,g=rX,o= /opt/tickets/api /opt/tickets/db
namei -l /opt/tickets/public/index.html
```

### C4. Secrets
```bash
sudo cp .env.example /etc/tickets/tickets.env && sudo nano /etc/tickets/tickets.env
sudo nano /etc/tickets/aiven-ca.pem          # paste the CA certificate
sudo chown root:tickets /etc/tickets/tickets.env /etc/tickets/aiven-ca.pem
sudo chmod 0640 /etc/tickets/tickets.env /etc/tickets/aiven-ca.pem
```

### C5. FPM pool on a Unix socket
```bash
sudo cp deploy/php-fpm/tickets.conf /etc/php/8.3/fpm/pool.d/tickets.conf
sudo mv /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.3/fpm/pool.d/www.conf.disabled   # save RAM
sudo php-fpm8.3 -t                                   # validate FPM config
sudo systemctl restart php8.3-fpm
ls -l /run/php/                                      # srw-rw---- www-data www-data php8.3-fpm-tickets.sock
sudo ss -xlp | grep tickets
```

### C6. Schema + seed (as the app user, with the CLI)
```bash
sudo -u tickets php /opt/tickets/db/seed.php
```

### C7. Nginx vhost (HTTP first)
```bash
IP=$(curl -s https://checkip.amazonaws.com)
sudo install -m 0755 scripts/nginx_vhost.sh /usr/local/bin/
sudo nginx_vhost.sh create --name tickets --domains "devops-tickets.duckdns.org ${IP}.sslip.io" \
     --web-root /opt/tickets/public --api-root /opt/tickets/api
cat /etc/nginx/sites-available/tickets.conf
ls -l /etc/nginx/sites-enabled/
curl -s http://$IP/api/health | jq          # "sapi":"fpm-fcgi","user":"tickets"
```

### C8. DuckDNS + cron
```bash
printf 'DUCKDNS_DOMAIN=devops-tickets\nDUCKDNS_TOKEN=your-token-here\n' | sudo tee /etc/tickets/duckdns.env >/dev/null
sudo chmod 600 /etc/tickets/duckdns.env
sudo install -m 0755 scripts/duckdns_update.sh /usr/local/bin/
sudo duckdns_update.sh
dig +short devops-tickets.duckdns.org        # = your IP (apt-get install dnsutils if missing)
( sudo crontab -l 2>/dev/null; echo '*/5 * * * * /usr/local/bin/duckdns_update.sh >/dev/null 2>&1' ) | sudo crontab -
sudo crontab -l
```

### C9. TLS with Certbot
```bash
sudo nginx_vhost.sh create --name tickets --domains "devops-tickets.duckdns.org ${IP}.sslip.io" \
     --certbot --email you@example.com --staging        # practice against staging first (no rate limits)
sudo certbot delete --cert-name devops-tickets.duckdns.org
sudo nginx_vhost.sh create --name tickets --domains "devops-tickets.duckdns.org ${IP}.sslip.io" \
     --certbot --email you@example.com                  # real certificate
sudo certbot certificates
systemctl list-timers | grep certbot
sudo certbot renew --dry-run
curl -sI https://devops-tickets.duckdns.org/ | head -3
curl -s  https://$IP.sslip.io/api/health | jq '.https'  # true
```
Log in at `https://devops-tickets.duckdns.org` with the seeded agent.

---

## Part D — Break-Fix Drills

### Drill 1 — 502 Bad Gateway: socket permission denied
**Break:** in the pool set `listen.mode = 0600`, `sudo systemctl restart php8.3-fpm`.
**Diagnose:**
```bash
sudo tail -n 3 /var/log/nginx/tickets.error.log    # connect() to unix:/run/php/… failed (13: Permission denied)
ls -l /run/php/php8.3-fpm-tickets.sock               # srw------- www-data …   (group can't write)
sudo -u www-data test -w /run/php/php8.3-fpm-tickets.sock || echo "www-data cannot write"
```
**Fix:** `listen.mode = 0660` + `listen.group = www-data`, restart FPM. **Lesson:** sockets obey file permissions; 502 with `(13:` = permissions, with `(2:` = socket missing (FPM down), with `(111:` = connection refused (TCP).

### Drill 2 — Login works on HTTPS but not on the raw IP (or vice versa)
**Break:** in `start_session()` set `'secure' => true` permanently.
**Symptom:** on `http://<IP>` login returns 200 but the next request says "login required".
**Diagnose:** browser DevTools → Application → Cookies (cookie marked *Secure*, not stored/sent over HTTP); `curl -si -X POST http://$IP/api/login -H 'Content-Type: application/json' -d '{"email":"…","password":"…"}' | grep -i set-cookie` → `secure`.
**Fix:** restore `'secure' => is_https()`. **Lesson:** cookie flags must match the scheme; ideally force HTTPS everywhere (certbot `--redirect`).

### Drill 3 — Certbot renewal fails silently after the IP changed
**Break:** stop/start the instance (new public IP) and disable the cron line.
**Symptom:** `https://devops-tickets.duckdns.org` times out; `sudo certbot renew --dry-run` fails with `Timeout during connect` / wrong IP.
**Diagnose:** `dig +short devops-tickets.duckdns.org` ≠ `curl -s https://checkip.amazonaws.com`; `journalctl -t duckdns -n 5`; `sudo crontab -l`.
**Fix:** re-add the cron line, run `sudo duckdns_update.sh`, re-run `certbot renew --dry-run`. Note the sslip.io name *also* changes with the IP → re-run `nginx_vhost.sh create … --certbot` with the new `<IP>.sslip.io`. **Lesson:** DNS must point at you for HTTP-01 to work; automate DNS updates.

**Bonus — `nginx -t` fails after a hand edit:** the script restores the previous config automatically; try adding a stray `}` to a template and run `nginx_vhost.sh create` — the site keeps serving.

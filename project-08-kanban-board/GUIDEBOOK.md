# Project 08 — Kanban Board · GUIDEBOOK

**Stack:** SolidJS (Vite build) · Deno 2 · CockroachDB Cloud (free tier) · Caddy
**Linux focus:** PM2 process manager (`ecosystem.config.js`, `pm2 startup`, `pm2 save`), `logrotate` internals, OpenSSL symmetric encryption, `umask`, secret hygiene
**Script:** `scripts/backup_env.sh`
**RAM budget:** Deno ≈ 40–60 MB · PM2 daemon (Node) ≈ 45 MB

---

## Part A — Concepts to Learn First

### A1. Why PM2 when we already have systemd?
You'll meet PM2 in many Node/JS shops. It's a **userspace process manager**: a long-running daemon (`God Daemon`, in `~/.pm2`) that forks your apps, restarts them, collects logs, shows a live dashboard (`pm2 monit`), supports cluster mode (Node only) and zero-downtime `pm2 reload`. Trade-off: PM2 itself must be started at boot — which it does by **generating a systemd unit** (`pm2 startup`). So systemd → PM2 daemon → your app.

| | systemd | PM2 |
|--|---------|-----|
| Runs as | PID 1 | a user's daemon |
| Config | unit files | `ecosystem.config.js` |
| Logs | journald | files (`~/.pm2/logs` or custom) → need **logrotate** |
| Limits | cgroups (`MemoryMax`) | `max_memory_restart` (polls RSS, restarts) |
| Boot | `enable` | `pm2 startup` + `pm2 save` |

### A2. The ecosystem file, field by field
* `script: /usr/local/bin/deno` + `interpreter: "none"` → PM2 execs the Deno binary directly (it's not only for Node).
* `args` → Deno permission flags: `--allow-net` `--allow-env` `--allow-read` `--allow-sys`; `--env-file=/etc/kanban/kanban.env` loads secrets (Deno reads it at startup).
* `autorestart`, `max_restarts`, `min_uptime`, `restart_delay`, `exp_backoff_restart_delay` → crash-loop protection.
* `max_memory_restart: "150M"` → PM2 checks RSS periodically and restarts above it (a *soft* limit, unlike a cgroup kill).
* `kill_timeout: 8000` → on stop PM2 sends **SIGINT**, waits 8 s, then SIGKILL. Our Deno code listens for SIGINT/SIGTERM and drains.
* `out_file`/`error_file`/`time`/`merge_logs` → log files with timestamps.

### A3. `pm2 startup` & `pm2 save`
`pm2 startup systemd -u kanban --hp /var/lib/kanban` prints a `sudo env PATH=… pm2 startup …` command that writes **`/etc/systemd/system/pm2-kanban.service`** (Type=forking, runs `pm2 resurrect` as user `kanban`). `pm2 save` writes the current process list to `~/.pm2/dump.pm2`; at boot `resurrect` reads it. Forget `pm2 save` → after reboot PM2 starts with **nothing**.

### A4. logrotate
Runs daily via `logrotate.timer` (systemd) reading `/etc/logrotate.conf` + `/etc/logrotate.d/*`. For each matching file: rename `out.log` → `out.log-20250131`, optionally compress older ones, delete beyond `rotate N`.
* **`create`** (default): move the file, create a fresh one → the app must **reopen** its log (e.g. via `postrotate` signal). Otherwise it keeps writing to the *renamed* file (open FD follows the inode).
* **`copytruncate`**: copy contents then truncate the original in place → the writer keeps its FD; tiny window where lines can be lost. Used for PM2 because it doesn't reopen logs on a signal.
* `su kanban kanban` — required when the log directory isn't root-owned (logrotate refuses "insecure permissions" otherwise).
* `delaycompress` keeps yesterday's file uncompressed (still being read by tools). `maxsize` rotates early if a file grows too big.
* Test: `logrotate -d` (debug/dry run), force: `logrotate -f`, state: `/var/lib/logrotate/status`.

### A5. Symmetric encryption with OpenSSL
`openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 -pass file:KEY`
* **AES-256-CBC**: block cipher, 256-bit key.
* **Salt** (random 8 bytes stored in the header `Salted__`) → the same passphrase never produces the same key twice.
* **PBKDF2 with 600 000 iterations** → derives the key from the passphrase slowly, so brute-forcing passphrases is expensive. (Without `-pbkdf2`, OpenSSL uses a weak legacy KDF and warns.)
* `-pass file:` keeps the passphrase **out of the process list** (`ps aux` would show `-pass pass:secret`!) and out of shell history.
* `enc` provides confidentiality, not authenticity → we add a **SHA-256 sidecar** to detect corruption; a wrong key shows `bad decrypt`.

### A6. `umask` & secret hygiene
`umask 077` → new files are `600`, dirs `700`. The script sets it first, so even temporary files and backups are never world-readable. Combine with: secrets only in `/etc/<app>/*.env` (`640 root:app`), never in Git, passphrase in a password manager **as well** as on the box (lose it = lose backups).

### A7. Deno 2 essentials
Secure by default: no file/network/env access unless granted by flags. Native TypeScript (no build). `npm:` specifiers import npm packages (we use `npm:postgres`). `DENO_DIR` = module cache location (we put it in `/var/lib/kanban/deno-cache`, writable by the app user).

### A8. CockroachDB Cloud quirks
Distributed SQL, Postgres wire-compatible, port **26257**, TLS required. Default isolation **SERIALIZABLE** → under contention transactions can fail with `40001 restart transaction`; clients must **retry** (see `withRetry()` in `db.ts`). UUID primary keys (`gen_random_uuid()`) avoid write hot-spots that sequential IDs cause in distributed DBs.

### A9. Bash concepts in `backup_env.sh`
`umask`, arrays for crypto flags (`CIPHER=(…)`; `"${CIPHER[@]}"`), `tar -C / … | openssl … -out` (streaming, no plaintext temp file), `mapfile -t arr < <(…)`, `ls -1t | tail -n +N` (everything except newest N), `diff <(…) <(…)` (compare key **names** without printing values), `find -print0 | while read -d ''` (filenames with spaces), `install -D -m -o -g` (create parents + set perms), `trap cleanup EXIT`.

---

## Part B — Architecture & Request Flow

```
 Browser (SolidJS SPA, drag & drop)
 https://<IP>.sslip.io
     │
     ▼
 ┌──────────────┐ /api/*  ┌──────────────── systemd: pm2-kanban.service (User=kanban) ───────────────┐
 │ Caddy :443   │───────▶ │  PM2 God Daemon (~/.pm2 = /var/lib/kanban/.pm2)                           │
 │ / → web/dist │ :5008   │    └─ kanban-api: /usr/local/bin/deno run --env-file=… main.ts            │
 └──────────────┘         │         autorestart · max_memory_restart 150M · kill_timeout 8s           │
                          │         logs → /var/log/kanban/{out,error}.log ──▶ logrotate (copytruncate)│
                          └───────────────────────────────┬──────────────────────────────────────────┘
                                                          │ Postgres wire protocol, TLS verify-full :26257
                                                          ▼
                                          ┌───────────────────────────────┐
                                          │ CockroachDB Cloud (free tier) │  SERIALIZABLE → retry 40001
                                          │ boards · columns · cards      │
                                          └───────────────────────────────┘
 /etc/kanban/kanban.env ──(tar | openssl enc AES-256 + PBKDF2)──▶ /var/backups/env/env-<host>-<ts>.tar.gz.enc (+ .sha256)
                                     key: /root/.config/backup_env/passphrase (0600)
```

---

## Part C — Step-by-Step Manual Deployment Lab

### C1. CockroachDB Cloud
Create a free cluster → SQL user `kanban_app` → database `kanban` → copy the connection string (`sslmode=verify-full`).

### C2. Install Deno and PM2
```bash
sudo systemctl disable --now snippetbin 2>/dev/null || true
cd /tmp && curl -fsSLO https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip
sudo unzip -o deno-x86_64-unknown-linux-gnu.zip -d /usr/local/bin && sudo chmod 755 /usr/local/bin/deno
deno --version
node -v || echo "install Node 22 first (Project 03 C2)"
sudo npm install -g pm2
pm2 --version
```

### C3. User with a home for PM2, directories
```bash
# PM2 needs a writable HOME for ~/.pm2 → give the system user a home in /var/lib (FHS: state)
sudo useradd --system --create-home --home-dir /var/lib/kanban --shell /usr/sbin/nologin --user-group kanban
sudo install -d -m 0755 -o root -g root /opt/kanban
sudo install -d -m 0750 -o root -g kanban /etc/kanban
sudo install -d -m 0750 -o kanban -g kanban /var/log/kanban /var/lib/kanban/deno-cache
cd ~/linux-devops-13-projects/project-08-kanban-board
sudo cp -r api /opt/kanban/ && sudo cp deploy/ecosystem.config.js /opt/kanban/
sudo chown -R root:kanban /opt/kanban && sudo chmod -R u=rwX,g=rX,o=rX /opt/kanban
sudo cp .env.example /etc/kanban/kanban.env && sudo nano /etc/kanban/kanban.env
sudo chown root:kanban /etc/kanban/kanban.env && sudo chmod 640 /etc/kanban/kanban.env
```

### C4. Cache deps + migrate (as the app user)
```bash
cd /opt/kanban/api
sudo -u kanban env DENO_DIR=/var/lib/kanban/deno-cache deno cache main.ts migrate.ts
sudo -u kanban env DENO_DIR=/var/lib/kanban/deno-cache deno run --allow-net --allow-env --allow-read --allow-sys \
     --env-file=/etc/kanban/kanban.env migrate.ts
```

### C5. Frontend build
```bash
cd ~/linux-devops-13-projects/project-08-kanban-board/web
npm install --no-audit --no-fund && NODE_OPTIONS=--max-old-space-size=384 npm run build
sudo install -d -m 0755 /opt/kanban/web && sudo rsync -a --delete dist/ /opt/kanban/web/dist/
```

### C6. PM2 lifecycle (as user kanban)
```bash
PM2="sudo -u kanban env HOME=/var/lib/kanban PM2_HOME=/var/lib/kanban/.pm2 pm2"
$PM2 start /opt/kanban/ecosystem.config.js
$PM2 ls
$PM2 describe kanban-api | head -30
$PM2 logs kanban-api --lines 20 --nostream
curl -s http://127.0.0.1:5008/api/health | jq
$PM2 restart kanban-api && $PM2 logs kanban-api --lines 5 --nostream    # "SIGINT received, draining … bye"
$PM2 save                                                              # writes dump.pm2
```

### C7. Boot persistence with `pm2 startup`
```bash
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u kanban --hp /var/lib/kanban
systemctl cat pm2-kanban | head -25
sudo systemctl enable pm2-kanban
sudo reboot
# after reconnecting:
systemctl status pm2-kanban --no-pager | head -5
sudo -u kanban env HOME=/var/lib/kanban PM2_HOME=/var/lib/kanban/.pm2 pm2 ls
```

### C8. logrotate
```bash
sudo cp ~/linux-devops-13-projects/project-08-kanban-board/deploy/logrotate-kanban /etc/logrotate.d/kanban
sudo logrotate -d /etc/logrotate.d/kanban 2>&1 | tail -15     # dry run, explains every decision
sudo logrotate -f /etc/logrotate.d/kanban
ls -l /var/log/kanban/                                          # out.log (truncated) + out.log-YYYYMMDD
curl -s http://127.0.0.1:5008/api/boards >/dev/null; tail -n1 /var/log/kanban/out.log   # still logging
grep kanban /var/lib/logrotate/status
```

### C9. Encrypted env backups
```bash
sudo install -m 0755 ~/linux-devops-13-projects/project-08-kanban-board/scripts/backup_env.sh /usr/local/bin/
sudo backup_env.sh init-key && sudo cat /root/.config/backup_env/passphrase   # store in your password manager
sudo backup_env.sh backup
sudo backup_env.sh backup --all
sudo backup_env.sh list
sudo head -c 16 /var/backups/env/env-*.enc | xxd | head -1      # "Salted__" header
B=$(sudo ls -1t /var/backups/env/*.enc | head -1)
sudo backup_env.sh verify "$B"
sudo backup_env.sh restore "$B"                                   # dry run: shows key differences only
echo '0 2 * * * root /usr/local/bin/backup_env.sh backup --all >> /var/log/backup_env.log 2>&1' | sudo tee /etc/cron.d/backup-env
```

### C10. Caddy
```bash
sudo cp ~/linux-devops-13-projects/project-08-kanban-board/deploy/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

---

## Part D — Break-Fix Drills

### Drill 1 — After reboot the API is gone (PM2 forgot it)
**Break:** `$PM2 delete kanban-api && $PM2 start /opt/kanban/ecosystem.config.js` (don't `save`), then delete it again with `$PM2 delete all`, `sudo reboot`.
**Symptom:** 502; `pm2 ls` empty though `pm2-kanban.service` is active.
**Diagnose:** `systemctl status pm2-kanban` OK → PM2 is running; `ls -l /var/lib/kanban/.pm2/dump.pm2` (old/empty).
**Fix:** `$PM2 start /opt/kanban/ecosystem.config.js && $PM2 save`. **Lesson:** `startup` = start PM2 at boot; `save` = what PM2 should start.

### Drill 2 — Disk fills up / logs stop rotating
**Break:** `sudo chmod 777 /var/log/kanban` then `sudo logrotate -f /etc/logrotate.d/kanban`.
**Symptom:** `error: skipping "/var/log/kanban/out.log" because parent directory has insecure permissions`.
**Diagnose:** `sudo logrotate -d /etc/logrotate.d/kanban`; `ls -ld /var/log/kanban`; `du -sh /var/log/kanban`.
**Fix:** `sudo chmod 750 /var/log/kanban` (the `su kanban kanban` line handles ownership). **Lesson:** logrotate refuses world-writable dirs (symlink attacks).

### Drill 3 — "bad decrypt" when restoring
**Break:** `sudo mv /root/.config/backup_env/passphrase /root/pp.bak && sudo backup_env.sh init-key`, then `sudo backup_env.sh verify <old backup>`.
**Symptom:** `bad decrypt` / `gzip: stdin: not in gzip format` → `decryption test FAILED`.
**Diagnose:** the new random passphrase ≠ the one used for old backups; checksum still OK (file is intact).
**Fix:** restore the original passphrase file (`mv /root/pp.bak …`, mode 600) and verify again. **Lesson:** encryption keys are backups' single point of failure — store them off-box.

**Bonus — `max_memory_restart` loop:** set it to `20M`, restart, watch `pm2 ls` restart counter climb (`↺`). Compare with Project 05's cgroup `MemoryMax` (kernel kill vs. PM2 polling restart).

# Project 03 — Habit Tracker · GUIDEBOOK

**Stack:** Alpine.js · Node.js 22 + Express · MongoDB Atlas M0 · Caddy
**Linux focus:** writing systemd `.service` units by hand, `daemon-reload/enable/start`, restart policies, cgroup limits, sandboxing, timers, `journalctl` filtering
**Script:** `scripts/service_audit.sh`
**RAM budget:** Node + Express + Mongo driver ≈ 55–75 MB (capped at 200 MB by the unit)

---

## Part A — Concepts to Learn First

### A1. What systemd is
`systemd` is **PID 1** — the first process the kernel starts. Everything else is its descendant. It:
* starts **units** in dependency order at boot,
* **supervises** them (restart on crash),
* places each service in its own **cgroup** (so it can count and limit memory/CPU and kill *every* child on stop),
* captures stdout/stderr into the **journal** (`journald`).

Compared with Project 02's `nohup` + watchdog: no orphan processes, no PID guessing, boot persistence, limits, logs — for free.

### A2. Unit file locations & precedence
| Path | Who writes it | Precedence |
|------|---------------|-----------|
| `/usr/lib/systemd/system/` | packages (apt) | lowest |
| `/etc/systemd/system/` | **you (admin)** | overrides vendor |
| `/etc/systemd/system/<unit>.d/*.conf` | drop-ins (`systemctl edit`) | merged on top |
| `/run/systemd/system/` | runtime, lost on reboot | highest |

`systemctl cat habits` shows the final file plus drop-ins. **`systemctl daemon-reload`** makes systemd re-read unit files from disk — forget it and your edits are ignored (systemd even warns: "unit file changed on disk").

### A3. Anatomy of `deploy/habits.service`
**`[Unit]`** — metadata and ordering
* `After=network-online.target` = *ordering* (start after). `Wants=` = *dependency* (pull it in). You usually need both.
* `StartLimitIntervalSec=60` + `StartLimitBurst=5` → after 5 starts in 60 s systemd stops trying (`start-limit-hit`). Reset with `systemctl reset-failed habits`.

**`[Service]`** — how to run it
* `Type=simple` → the process in `ExecStart` *is* the service; systemd considers it started immediately.
* `User=`/`Group=` → drop root before exec.
* `EnvironmentFile=` → `KEY=value` lines loaded into the environment. Readable by root only; systemd reads it **as root**, before dropping privileges — so mode `0640 root:habits` is fine (and `0600 root:root` would also work).
* `ExecStart=` needs an **absolute path** (`/usr/bin/node`, not `node`).
* `Restart=on-failure` → restart on non-zero exit, signal kill, timeout, watchdog. (`always` would restart even after clean exit 0.)
* `RestartPreventExitStatus=78` → our app exits 78 (EX_CONFIG) when `MONGODB_URI` is missing; restarting can't fix config, so don't.
* `KillSignal=SIGTERM` + `TimeoutStopSec=10` → TERM, wait 10 s, then SIGKILL the whole cgroup.
* `MemoryHigh=150M` throttles/reclaims; `MemoryMax=200M` → the kernel OOM-kills inside the cgroup (status `9/KILL`, `Result=oom-kill`). This protects the *rest* of the 1 GB box.
* Sandboxing: `ProtectSystem=strict` (whole FS read-only except `/dev`,`/proc`,`/sys`), `ProtectHome=true` (no `/home`), `PrivateTmp=true` (own `/tmp`), `NoNewPrivileges=true` (setuid binaries can't escalate), `CapabilityBoundingSet=` (empty = no Linux capabilities at all). Score it with `systemd-analyze security habits`.

**`[Install]`** — what `enable` does
`WantedBy=multi-user.target` → `systemctl enable` creates a **symlink** `/etc/systemd/system/multi-user.target.wants/habits.service → ../habits.service`. At boot, reaching multi-user.target pulls in everything in its `.wants/` directory. `enable` ≠ `start`; `enable --now` = both.

### A4. Service states you'll see
`systemctl status` → `Loaded: loaded (...; enabled; preset: enabled)` / `Active: active (running)` / `activating (auto-restart)` / `failed (Result: exit-code)`. `systemctl show -p NRestarts habits` counts restarts.

### A5. journald & `journalctl` filtering
Logs are stored in binary form in `/var/log/journal/` (persistent on Ubuntu). Each line carries metadata fields (`_SYSTEMD_UNIT`, `_PID`, `PRIORITY`, `SYSLOG_IDENTIFIER`).

| Need | Command |
|------|---------|
| one unit | `journalctl -u habits` |
| follow (tail -f) | `journalctl -u habits -f` |
| last 50, no pager | `journalctl -u habits -n 50 --no-pager` |
| time window | `--since "10 min ago"` / `--since today --until "2025-01-01 12:00"` |
| errors only | `-p err` (0 emerg … 3 err, 4 warning, 6 info, 7 debug) |
| this boot | `-b`; previous boot `-b -1` |
| by identifier | `journalctl -t habits` |
| by PID | `journalctl _PID=1234` |
| JSON for tooling | `-o json-pretty` / `-o cat` (message only) |
| grep inside | `journalctl -u habits -g 'ERROR|FATAL'` |
| disk usage | `journalctl --disk-usage`; trim: `sudo journalctl --vacuum-size=200M` |

Node's `console.log` → stdout → journal priority **info**; `console.error` → stderr → still info unless you configure otherwise. That is why our app *prefixes* `ERROR`/`WARN`, and why `journalctl -g ERROR` is useful.

### A6. Timers (cron's modern replacement)
A `.timer` activates a `.service` of the same name. `OnCalendar=*-*-* 06:00:00 UTC` (test with `systemd-analyze calendar '*-*-* 06:00'`), `Persistent=true` = run on next boot if the machine was off at 06:00. List: `systemctl list-timers`.

### A7. MongoDB Atlas M0 essentials
* Free shared cluster (512 MB storage). Connection string `mongodb+srv://` uses a **DNS SRV record** to discover replica-set members, then TLS on 27017.
* **Network Access list** must include `<EC2_IP>/32` — otherwise the driver times out with `MongoServerSelectionError` (classic drill!).
* Create a **database user** with `readWrite` on `habits` only (least privilege).

### A8. Node.js on a small box
`--max-old-space-size=128` caps V8's heap so Node garbage-collects earlier instead of growing until the cgroup kills it.

### A9. Bash concepts in `service_audit.sh`
Associative arrays (`declare -A`), `while IFS='=' read -r k v` over **process substitution** `< <(cmd)`, `systemctl show -p` (machine-readable), `[[ -t 1 ]]` (is stdout a terminal? → colours only for humans), parameter expansion `${t%%:*}` / `${t##*:}` (split `unit:port`), `exec 3>&1 1>/dev/null` (file-descriptor juggling for `--json` mode), meaningful **exit codes** for monitoring.

---

## Part B — Architecture & Request Flow

```
 Browser (Alpine.js)
 https://<IP>.sslip.io
     │
     ▼
 ┌──────────────┐  127.0.0.1:5003  ┌──────────────────────────── cgroup: habits.service ──────────────┐
 │ Caddy :443   │ ───────────────▶ │ /usr/bin/node /opt/habits/server/server.js   (User=habits)       │
 └──────────────┘                  │ MemoryMax=200M · ProtectSystem=strict · Restart=on-failure        │
                                   │ stdout/stderr ─────────────▶ journald (journalctl -u habits)      │
                                   └──────────────────────┬────────────────────────────────────────────┘
                                                          │ mongodb+srv:// (DNS SRV → TLS 27017)
                                                          ▼
                                             ┌────────────────────────────┐
                                             │ MongoDB Atlas M0           │  Network Access: <EC2_IP>/32
                                             │ db: habits / coll: habits  │
                                             └────────────────────────────┘
 PID 1 systemd ──▶ multi-user.target.wants/habits.service (enable symlink)
              └──▶ timers.target.wants/habits-audit.timer ──▶ habits-audit.service ──▶ service_audit.sh
```

---

## Part C — Step-by-Step Manual Deployment Lab

### C1. Atlas setup (browser)
1. Create a free **M0** cluster. 2. *Database Access* → user `habits_app` / strong password / role `readWrite@habits`. 3. *Network Access* → **Add IP** → `<EC2_IP>/32`. 4. *Connect → Drivers* → copy the `mongodb+srv://` URI.

### C2. Node.js 22 LTS from NodeSource
```bash
curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh
less /tmp/nodesource_setup.sh            # read before you run anything piped from the internet
sudo bash /tmp/nodesource_setup.sh
sudo apt-get install -y nodejs
node -v && npm -v && which node          # /usr/bin/node — the path used in ExecStart
```

### C3. User, directories, code
```bash
sudo systemctl disable --now bookmarks 2>/dev/null || true      # free RAM from Project 02
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group habits
sudo install -d -m 0755 -o root -g root   /opt/habits
sudo install -d -m 0750 -o root -g habits /etc/habits
sudo cp -r ~/linux-devops-13-projects/project-03-habit-tracker/server /opt/habits/
sudo cp ~/linux-devops-13-projects/project-03-habit-tracker/GUIDEBOOK.md /opt/habits/
cd /opt/habits/server && sudo npm install --omit=dev --no-audit --no-fund
sudo chown -R root:habits /opt/habits && sudo chmod -R u=rwX,g=rX,o=rX /opt/habits
```

### C4. Environment file
```bash
sudo cp ~/linux-devops-13-projects/project-03-habit-tracker/.env.example /etc/habits/habits.env
sudo nano /etc/habits/habits.env          # paste your Atlas URI
sudo chown root:habits /etc/habits/habits.env && sudo chmod 0640 /etc/habits/habits.env
```

### C5. Seed with a one-off transient unit (no shell as the app user needed)
```bash
sudo systemd-run --uid=habits --gid=habits --wait --pipe \
  -p EnvironmentFile=/etc/habits/habits.env -p WorkingDirectory=/opt/habits/server \
  /usr/bin/node seed.js
```

### C6. Install, reload, enable, start
```bash
sudo cp ~/linux-devops-13-projects/project-03-habit-tracker/deploy/habits.service /etc/systemd/system/
sudo systemd-analyze verify /etc/systemd/system/habits.service   # lint the unit
sudo systemctl daemon-reload
sudo systemctl enable --now habits
ls -l /etc/systemd/system/multi-user.target.wants/ | grep habits  # the enable symlink
systemctl status habits --no-pager
systemctl show -p MainPID,NRestarts,MemoryCurrent,ActiveState habits
sudo ss -tlnp | grep 5003
curl -s http://127.0.0.1:5003/api/health | jq
```

### C7. Observe supervision & limits
```bash
sudo kill -9 $(systemctl show -p MainPID --value habits)     # simulate a crash
sleep 4; systemctl status habits --no-pager | head -5         # restarted, new PID
systemctl show -p NRestarts habits
sudo systemctl stop habits; journalctl -u habits -n 5 --no-pager   # "SIGTERM received … shutdown complete"
sudo systemctl start habits
systemd-analyze security habits | tail -1                      # exposure score
systemd-cgls -u habits.service                                  # the cgroup tree
```

### C8. journalctl drills
```bash
journalctl -u habits -f                         # (Ctrl+C to exit) refresh the browser meanwhile
journalctl -u habits --since "5 min ago" -g 'POST|DELETE' --no-pager
journalctl -u habits -o json-pretty -n 1
journalctl -t habits -p warning --since today
```

### C9. Caddy + the audit timer
```bash
sudo cp ~/linux-devops-13-projects/project-03-habit-tracker/deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo install -m 0755 ~/linux-devops-13-projects/project-03-habit-tracker/scripts/service_audit.sh /usr/local/bin/
sudo service_audit.sh habits.service:5003 caddy.service:443 ssh.service:22 --security
sudo service_audit.sh --json habits.service:5003 | jq
sudo cp ~/linux-devops-13-projects/project-03-habit-tracker/deploy/habits-audit.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now habits-audit.timer
systemctl list-timers habits-audit.timer
sudo systemctl start habits-audit.service && journalctl -t service-audit -n 20 --no-pager
```
Open `https://<EC2_IP>.sslip.io` ✅

---

## Part D — Break-Fix Drills

### Drill 1 — `status=203/EXEC`
**Break:** change `ExecStart=/usr/bin/node` to `ExecStart=node` (or `/usr/local/bin/node`), `daemon-reload`, restart.
**Symptom:** `Main process exited, code=exited, status=203/EXEC`.
**Diagnose:** `journalctl -u habits -n 20` → "Failed to locate executable" / "No such file or directory"; `which node`.
**Fix:** absolute path, `daemon-reload`, `restart`. **Lesson:** systemd has no `$PATH` lookup magic for you; 203 = exec failed (also caused by missing `+x` or wrong shebang).

### Drill 2 — `start-limit-hit` crash loop from Atlas IP allow-list
**Break:** in Atlas, delete `<EC2_IP>/32` from Network Access. `sudo systemctl restart habits`.
**Symptom:** after ~5 restarts: `Failed with result 'start-limit-hit'`; health → 502.
**Diagnose:**
```bash
systemctl status habits --no-pager
journalctl -u habits -g 'FATAL|ServerSelection' --since "10 min ago"
sudo service_audit.sh habits.service:5003; echo "exit=$?"
```
**Fix:** re-add the IP, then `sudo systemctl reset-failed habits && sudo systemctl start habits`. **Lesson:** StartLimit protects the box; `reset-failed` clears the counter.

### Drill 3 — "I edited the unit but nothing changed" + OOM kill
**Break A:** change `MemoryMax=200M` to `MemoryMax=40M` and run `sudo systemctl restart habits` **without** `daemon-reload`.
**Symptom A:** `Warning: The unit file … changed on disk. Run 'systemctl daemon-reload'`; `systemctl show -p MemoryMax habits` still shows 200M.
**Break B:** now `daemon-reload` + restart. Node can't fit in 40 MB.
**Symptom B:** `Result: oom-kill`, `status=9/KILL`; `journalctl -k -g oom` / `dmesg | grep -i 'memory cgroup out of memory'`.
**Fix:** restore 200M, `daemon-reload`, `restart`. **Lesson:** `daemon-reload` after every unit edit; cgroup limits produce exit 137-style kills (Project 05 goes deeper).

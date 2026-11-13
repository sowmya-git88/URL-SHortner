# Project 02 — Bookmark Manager · GUIDEBOOK

**Stack:** HTMX · Go 1.22 (one static binary with embedded templates) · Turso LibSQL (hosted SQLite) · Caddy
**Linux focus:** users & groups, process lifecycle, job control (`&`, `jobs`, `fg`, `bg`, `Ctrl+Z`), `nohup`, signals (`kill -15` vs `kill -9`), `htop`
**Script:** `scripts/health_watch.sh`
**RAM budget:** Go binary ≈ 12–20 MB RSS · build needs ~400 MB (swap helps)

---

## Part A — Concepts to Learn First

### A1. Users, groups and what `useradd` really writes
| File | Content |
|------|---------|
| `/etc/passwd` | `name:x:UID:GID:comment:home:shell` — public, world-readable |
| `/etc/shadow` | password hashes — root only (`0640 root:shadow`) |
| `/etc/group` | `group:x:GID:member1,member2` |

* `useradd --system` picks a UID < 1000 and doesn't create mailbox/aging info.
* `--shell /usr/sbin/nologin` → `su - bookmarks` prints "This account is currently not available".
* `usermod -aG bookmarks ubuntu` adds a **supplementary** group. **`-a` is critical**: without it `-G` *replaces* all supplementary groups (you could remove yourself from `sudo`!).
* Group membership is read **at login**. After `usermod`, run `newgrp bookmarks` or log out/in. Check with `id` and `groups`.

Design used here: user `bookmarks` runs the binary; group `bookmarks` also contains `ubuntu` so you can read logs in `/var/log/bookmarks` without sudo (dir mode `2770` — the **setgid bit** `2` makes new files inherit the directory's group).

### A2. What is a process?
A running program = a **PID**, a parent (**PPID**), a user (**UID**), memory, open file descriptors (0 stdin, 1 stdout, 2 stderr), and a **state**: `R` running, `S` sleeping, `D` uninterruptible I/O, `T` stopped, `Z` zombie. See them in `/proc/<pid>/` — `cat /proc/<pid>/status`, `ls -l /proc/<pid>/fd`.

Processes form a tree (`pstree -p`). Every login shell is a **session leader**; its children belong to a **process group** per pipeline/job.

### A3. Job control in an interactive shell
| Action | Effect |
|--------|--------|
| `cmd &` | start in **background**; shell prints `[1] 12345` (job number, PID) |
| `Ctrl+Z` | send **SIGTSTP** → process **stopped** (state `T`), not running! |
| `jobs -l` | list jobs of *this* shell |
| `bg %1` | resume job 1 in the background (SIGCONT) |
| `fg %1` | bring job 1 to the foreground |
| `kill %1` | signal by job number |
| `disown %1` | remove from the shell's job table (won't get SIGHUP) |

Jobs are **per shell**: open a second SSH session and `jobs` is empty — but `ps`/`pgrep` still see the process.

### A4. Why `nohup` exists — SIGHUP
When your SSH session closes, the kernel sends **SIGHUP** ("hang-up") to the session's process group. The default action of SIGHUP is *terminate*. `nohup cmd &` sets SIGHUP to *ignored* and, if stdout is a terminal, redirects it to `nohup.out`. Better: redirect explicitly: `nohup ./app >> app.log 2>&1 &`.
`setsid` goes further: new session, no controlling terminal at all.

**Limitation (motivation for Project 03):** nothing restarts the app after a crash or reboot. That is what `health_watch.sh` (poor man's supervisor) and later systemd solve.

### A5. Signals: `kill -15` vs `kill -9`
`kill` just *sends a signal*. Common ones (`kill -l` lists all):

| # | Name | Default | Catchable? | Typical meaning |
|---|------|---------|------------|-----------------|
| 1 | SIGHUP | terminate | yes | terminal closed / "reload config" |
| 2 | SIGINT | terminate | yes | Ctrl+C |
| 9 | **SIGKILL** | terminate | **NO** | kernel kills instantly — no cleanup |
| 15 | **SIGTERM** | terminate | yes | "please shut down" (default of `kill`) |
| 19 | SIGSTOP | stop | NO | freeze |
| 20 | SIGTSTP | stop | yes | Ctrl+Z |
| 18 | SIGCONT | continue | yes | resume |
| 10 | SIGUSR1 | terminate | yes | app-defined — **our binary prints stats** |

Our Go binary uses `signal.NotifyContext(..., SIGINT, SIGTERM)` and calls `http.Server.Shutdown()`: stop accepting, finish in-flight requests, close DB, exit 0. With **SIGKILL** none of that runs: half-written responses, open transactions rolled back by the DB, temp files left behind. Rule: **always TERM first, KILL only after a timeout** (`health_watch.sh` and systemd's `TimeoutStopSec` do exactly this).

Exit status after a signal = **128 + signal number**: SIGTERM → 143, SIGKILL → **137** (remember it for Project 05).

### A6. `htop` / `top` reading guide
* **Load average** (1/5/15 min): runnable + D-state tasks. On 1 vCPU, > 1.0 means queueing.
* **RES** = resident RAM actually used. **VIRT** = address space (ignore it, Go reserves a lot).
* `F4` filter, `F5` tree view, `F6` sort, `F9` send a signal (choose 15!), `u` filter by user.

### A7. Why Go is a perfect fit for 1 GB
Go compiles to **one static binary**; with `//go:embed` the HTML templates, CSS and SQL migrations are *inside* the binary. Deploy = copy one file. Runtime ≈ 15 MB. The compile step is the heavy part, so use `go build -p 1` (one package at a time) and keep the 2 GB swap from Project 01.

### A8. Turso / LibSQL
LibSQL is an open-source fork of SQLite; Turso hosts it and exposes it over HTTPS/WebSockets (`libsql://…`). The Go driver `libsql-client-go` speaks that protocol in pure Go (no CGO), so it is just another `database/sql` driver. Auth = a JWT appended as `?authToken=`.

### A9. HTMX in one paragraph
Instead of a JS SPA, HTML attributes issue requests and swap **server-rendered HTML fragments**: `hx-post="/bookmarks" hx-target="#list" hx-swap="afterbegin"` posts the form and inserts the returned `<li>` at the top of the list. The server stays the single source of truth; there is no build step.

### A10. Bash concepts in `health_watch.sh`
`pgrep -x -o` (exact, oldest), `kill -0 PID` (does it exist? sends nothing), `/proc/PID/status` parsing with `awk`, `flock -n` (one instance only), `trap cleanup INT TERM`, `sleep & wait $!` (so traps fire immediately), `set -a; . file; set +a` (export everything sourced), `runuser -u` (become the app user without a password), `setsid nohup … &` (detach completely).

---

## Part B — Architecture & Request Flow

```
 Browser (HTMX)                         EC2 (1 GB)
 https://<IP>.sslip.io
     │ hx-post /bookmarks
     ▼
 ┌──────────────┐ reverse_proxy  ┌────────────────────────────────────┐  HTTPS (libsql protocol) ┌──────────────────┐
 │ Caddy :443   │ ─────────────▶ │ /opt/bookmarks/bin/bookmarks       │ ───────────────────────▶ │ Turso (LibSQL)   │
 │ health_uri   │ 127.0.0.1:5002 │  user=bookmarks  pid=NNNN          │   authToken=JWT          │ bookmarks db     │
 └──────────────┘                │  embeds: templates/ static/ sql/   │                          └──────────────────┘
                                 │  SIGTERM → graceful drain          │
                                 │  SIGUSR1 → stats to log            │
                                 └───────────────▲────────────────────┘
                                                 │ pgrep / curl /api/health / VmRSS
                                 ┌───────────────┴────────────────────┐
                                 │ health_watch.sh --loop (nohup)     │ → /var/log/bookmarks/health_watch.log
                                 └────────────────────────────────────┘
```

---

## Part C — Step-by-Step Manual Deployment Lab

### C1. Create the Turso database (on your laptop or the EC2 box)
```bash
curl -sSfL https://get.tur.so/install.sh | bash
exec $SHELL -l
turso auth signup            # or: turso auth login  (opens a browser / prints a URL)
turso db create bookmarks
turso db show bookmarks --url        # libsql://bookmarks-<you>.turso.io
turso db tokens create bookmarks     # long JWT
```

### C2. Users and groups
```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group bookmarks
sudo usermod -aG bookmarks ubuntu          # -a = append!
newgrp bookmarks                            # or re-login
id; getent group bookmarks; grep bookmarks /etc/passwd
sudo install -d -m 0755 -o root -g root       /opt/bookmarks /opt/bookmarks/bin
sudo install -d -m 0750 -o root -g bookmarks  /etc/bookmarks
sudo install -d -m 2770 -o bookmarks -g bookmarks /var/log/bookmarks
ls -ld /var/log/bookmarks     # drwxrws--- : the 's' is the setgid bit
```

### C3. Build the binary
```bash
sudo apt-get install -y golang-go      # Ubuntu 24.04 ships Go 1.22
go version
cd ~/linux-devops-13-projects/project-02-bookmark-manager/app
go mod tidy                            # resolves libsql-client-go, writes go.sum
CGO_ENABLED=0 go build -p 1 -trimpath -ldflags='-s -w' -o bookmarks .
ls -lh bookmarks && file bookmarks     # "statically linked"
sudo install -m 0755 -o root -g root bookmarks /opt/bookmarks/bin/bookmarks
```
> If the build is killed (`signal: killed`) you hit the OOM killer → confirm swap: `swapon --show`.

### C4. Configuration
```bash
sudo cp ../.env.example /etc/bookmarks/bookmarks.env
sudo nano /etc/bookmarks/bookmarks.env         # paste TURSO_DATABASE_URL + TURSO_AUTH_TOKEN
sudo chown root:bookmarks /etc/bookmarks/bookmarks.env && sudo chmod 0640 /etc/bookmarks/bookmarks.env
```

### C5. Job control lab (foreground → background → stop → resume)
```bash
# run as the app user in an interactive shell (bash -s gives us a shell despite nologin)
sudo -u bookmarks bash
set -a; . /etc/bookmarks/bookmarks.env; set +a
/opt/bookmarks/bin/bookmarks -seed             # foreground: logs on screen, prompt blocked
# press Ctrl+Z
jobs -l                                        # [1]+ Stopped
curl -m 3 -s http://127.0.0.1:5002/api/health  # hangs/times out: a STOPPED process cannot answer
bg %1                                          # resume in background
curl -s http://127.0.0.1:5002/api/health; echo
fg %1                                          # back to foreground, then Ctrl+C (SIGINT → graceful "bye")
exit
```

### C6. Signals lab
```bash
sudo -u bookmarks bash -c 'set -a; . /etc/bookmarks/bookmarks.env; set +a; nohup /opt/bookmarks/bin/bookmarks >> /var/log/bookmarks/app.log 2>&1 &'
PID=$(pgrep -x bookmarks); echo $PID
ps -o pid,ppid,user,stat,rss,etime,cmd -p $PID
sudo kill -USR1 $PID && tail -n 2 /var/log/bookmarks/app.log      # stats line, process keeps running
sudo kill -15 $PID   && tail -n 3 /var/log/bookmarks/app.log      # "draining connections" … "bye"
# start again, then compare with SIGKILL
sudo -u bookmarks bash -c 'set -a; . /etc/bookmarks/bookmarks.env; set +a; nohup /opt/bookmarks/bin/bookmarks >> /var/log/bookmarks/app.log 2>&1 &'
sudo kill -9 $(pgrep -x bookmarks); tail -n 2 /var/log/bookmarks/app.log    # no "bye" — no cleanup ran
```
In a second terminal keep `htop -u bookmarks` open (F5 tree, F9 → choose 15 SIGTERM) and watch.

### C7. Survive logout with nohup + the watchdog
```bash
sudo install -m 0755 ~/linux-devops-13-projects/project-02-bookmark-manager/scripts/health_watch.sh /usr/local/bin/health_watch.sh
sudo health_watch.sh --once || echo "unhealthy (expected if not running)"
sudo nohup /usr/local/bin/health_watch.sh --loop --interval 10 --max-fails 2 >/dev/null 2>&1 &
sleep 25; tail -n 5 /var/log/bookmarks/health_watch.log      # it noticed the app was down and started it
exit   # log out completely, SSH back in:
pgrep -a bookmarks; pgrep -af health_watch                   # both still alive thanks to nohup/setsid
```

### C8. Caddy and verification
```bash
sudo cp ~/linux-devops-13-projects/project-02-bookmark-manager/deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo ss -tulpn | grep -E '5002|:443'
curl -s https://$(curl -s https://checkip.amazonaws.com).sslip.io/api/health | jq
```

### C9. Graduate to systemd (preview of Project 03)
```bash
sudo pkill -f 'health_watch.sh --loop'; sudo pkill -TERM -x bookmarks
sudo cp ~/linux-devops-13-projects/project-02-bookmark-manager/deploy/bookmarks.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now bookmarks
systemctl status bookmarks --no-pager
```

---

## Part D — Break-Fix Drills

### Drill 1 — "The app dies every time I close my laptop"
**Break:** start the binary with `./bookmarks &` (no nohup) in an SSH session, then close the terminal window.
**Diagnose:** reconnect, `pgrep -a bookmarks` → nothing; `sudo journalctl _COMM=sshd --since '10 min ago'` shows the session ended.
**Fix:** `nohup … >> log 2>&1 &` or `setsid`, or (correct answer) a systemd unit. **Lesson:** SIGHUP to the session's process group.

### Drill 2 — Service hangs on stop / port stays busy
**Break:** run two copies: start one with nohup, then try a second → log shows `bind: address already in use`.
**Diagnose:**
```bash
sudo ss -tlnp 'sport = :5002'          # who owns the port?
pgrep -a bookmarks                      # several PIDs?
sudo lsof -i :5002
```
**Fix:** `sudo kill -15 <old-pid>`; wait; if still present after 10 s `kill -9`. Use `flock` (as `health_watch.sh` does) or systemd to guarantee a single instance.

### Drill 3 — `/api/health` returns 503 "degraded" but the process is fine
**Break:** put a wrong `TURSO_AUTH_TOKEN` in the env file and restart.
**Diagnose:**
```bash
curl -s http://127.0.0.1:5002/api/health | jq .error     # 401 / unauthorized from Turso
sudo health_watch.sh --once; echo "exit=$?"               # 1 → unhealthy
turso db tokens create bookmarks                           # new token
```
**Fix:** update the env file (`0640 root:bookmarks`), `kill -15` the app (the watchdog restarts it with the new env). **Lesson:** a liveness check (process exists) is not a readiness check (dependency works) — and restarting does not fix a bad credential; the watchdog would loop forever, which is why it logs every attempt.

**Bonus:** `usermod -G bookmarks ubuntu` (without `-a`) → you lose `sudo`. Recovery: EC2 Instance Connect as `ubuntu` won't help; use **Session Manager** or a rescue instance and edit `/etc/group`. Always `-aG`.

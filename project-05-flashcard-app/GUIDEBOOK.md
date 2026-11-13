# Project 05 — Flashcard App · GUIDEBOOK

**Stack:** Svelte 5 (Vite build) · Hono (TypeScript on Node 22) · Supabase Postgres · Caddy
**Linux focus:** virtual memory, page cache, swap (`fallocate`, `mkswap`, `swapon`, `/etc/fstab`), `swappiness`, the OOM killer, exit code **137**, cgroup memory limits, `free -h`, PSI
**Script:** `scripts/swap_guard.sh`
**RAM budget:** API ≈ 60 MB · `vite build` peak ≈ 250–350 MB · `tsc` ≈ 150 MB

---

## Part A — Concepts to Learn First

### A1. How Linux uses RAM
Linux tries to use **all** RAM: free RAM is wasted RAM. Memory is roughly:
* **Anonymous memory** — process heaps/stacks (Node's V8 heap). Can only be freed by the process or by writing it to **swap**.
* **Page cache** — file contents cached from disk. Can be dropped instantly (it's still on disk) → counts as "available".
* **Kernel** — slab caches, page tables, network buffers.

### A2. Reading `free -h` correctly
```
               total        used        free      shared  buff/cache   available
Mem:           957Mi       512Mi        73Mi       2.0Mi       372Mi       300Mi
Swap:          2.0Gi       120Mi       1.9Gi
```
* **free** = completely unused (small is normal!).
* **buff/cache** = page cache, mostly reclaimable.
* **available** = the number that matters: estimate of RAM obtainable for new processes **without swapping**. Alert on *available*, not *free*.

### A3. Swap
Swap is disk space used as overflow for anonymous memory. When RAM is tight the kernel **pages out** cold pages to swap and pages them back in on access (**page fault**). Disk is ~1000× slower than RAM, so heavy swapping (**thrashing**) makes everything slow — but slow beats *dead*. On a 1 GB box swap is your insurance for **builds** (`npm install`, `vite build`, `go build`).

Swap file lifecycle:
| Command | What happens under the hood |
|---------|-----------------------------|
| `fallocate -l 2G /swapfile` | reserves contiguous blocks instantly (no zero writing) |
| `chmod 600 /swapfile` | swap may contain passwords/keys from RAM → root only |
| `mkswap /swapfile` | writes a swap **signature/header** (like formatting) |
| `swapon /swapfile` | kernel starts using it *now* (until reboot) |
| `/etc/fstab: /swapfile none swap sw 0 0` | re-enabled on every boot by `systemd-fstab-generator` → `swapfile.swap` unit |
| `swapon --show` / `cat /proc/swaps` | verify |

A **typo in `/etc/fstab`** can drop the next boot into emergency mode — verify with `findmnt --verify` (the script does).

### A4. `vm.swappiness` & `vfs_cache_pressure`
`swappiness` (0–200, default 60) = relative preference for swapping anonymous memory vs dropping page cache. `10` → "keep my app in RAM, drop file cache first". Set persistently in `/etc/sysctl.d/*.conf`, apply with `sysctl --system` / `sysctl -p file`.

### A5. The OOM killer and exit code 137
If RAM + swap are exhausted and nothing can be reclaimed, the kernel's **OOM killer** chooses a victim by **`oom_score`** (mostly: who uses the most memory, adjusted by `oom_score_adj` −1000…+1000) and sends **SIGKILL**. The process cannot catch it. The parent sees exit status **128 + 9 = 137**:
* shell: `echo $?` → `137`; `npm run build` → `Killed`
* Docker: `Exited (137)`, `OOMKilled: true`
* systemd: `status=9/KILL`, `Result: oom-kill`
* kernel log: `Out of memory: Killed process 1234 (node) total-vm:… anon-rss:…` → `journalctl -k -g oom` or `dmesg -T | grep -i oom`

`cat /proc/<pid>/oom_score` shows the current score. We set `OOMScoreAdjust=300` on the API so the kernel prefers killing it over `sshd` (your lifeline).

### A6. cgroup limits vs. global OOM
systemd puts every service in a **cgroup v2**. `MemoryMax=180M` → when *that service* exceeds 180 MB, the kernel OOM-kills **inside the cgroup** only, even if the box has free RAM. `MemoryHigh=` → soft limit: the kernel reclaims aggressively and throttles first. `MemorySwapMax=` caps swap per service. Inspect: `systemctl show -p MemoryCurrent,MemoryPeak flashcards` and `cat /sys/fs/cgroup/system.slice/flashcards.service/memory.events` (look at `oom_kill`).

### A7. Node.js memory knobs
V8's default heap limit is sized for big machines. `--max-old-space-size=96` (MB) makes Node garbage-collect harder and throw a JS *"heap out of memory"* error (exit 134, SIGABRT) before the cgroup kills it with 137 — easier to debug. The **build** step uses `NODE_OPTIONS=--max-old-space-size=384` so Vite has room (with swap).

### A8. PSI — Pressure Stall Information
`/proc/pressure/memory` → `some avg10=…` = % of time at least one task was stalled waiting for memory in the last 10 s. Non-zero sustained values = you're swapping/reclaiming hard.

### A9. Supabase connection pooling
Supabase's **transaction pooler** (Supavisor, port **6543**) multiplexes many clients onto few Postgres connections, but connections are reassigned per transaction → **prepared statements break**. Hence `prepare: false` in `db.ts`. Direct port 5432 is IPv6-only on some plans; the pooler works over IPv4 (EC2 default).

### A10. Bash concepts in `swap_guard.sh`
Subcommand dispatch with `case`, reading `/proc/meminfo` with `awk -v`, integer math `$(( ))`, `${1^^}` (uppercase), suffix stripping `${s%G}`, globbing `/proc/[0-9]*/status`, `logger -t` (write to syslog/journal), `sed -i.bak "\|pattern|d"` (custom delimiter to avoid escaping `/`), `findmnt --verify`, `sleep & wait $!` for responsive traps.

---

## Part B — Architecture & Request Flow

```
 Browser (Svelte SPA)
 https://<IP>.sslip.io
     │
     ▼
 ┌───────────────┐  /api/*   ┌────────────────────────── cgroup flashcards.service ──────────────┐   TLS :6543   ┌───────────────────────┐
 │ Caddy :443    │ ────────▶ │ node --max-old-space-size=96 dist/index.js  (Hono)                 │ ────────────▶ │ Supabase Supavisor    │
 │ / → web/dist  │ 127.0.0.1 │ MemoryHigh=140M MemoryMax=180M MemorySwapMax=100M OOMScoreAdj=300  │ prepare:false │ (transaction pooler)  │
 └───────────────┘   :5005   └────────────────────────────────────────────────────────────────────┘               │ → Postgres decks/cards│
                                                                                                                  └───────────────────────┘
 ┌──────────────────────────── 1 GB RAM ────────────────────────────┐   ┌────────── /swapfile 2 GB (disk) ─────────┐
 │ kernel · sshd · caddy · node API · page cache (reclaimable)      │◀─▶│ cold anonymous pages (vite/tsc builds)    │
 └──────────────────────────────────────────────────────────────────┘   └──────────────────────────────────────────┘
          ▲ swap_guard.sh watch → logger → journal (WARN when available < 100 MB or swap > 80%)
```

---

## Part C — Step-by-Step Manual Deployment Lab

### C1. Observe the box *without* swap (controlled experiment)
```bash
sudo systemctl disable --now expense 2>/dev/null || true
sudo install -m 0755 ~/linux-devops-13-projects/project-05-flashcard-app/scripts/swap_guard.sh /usr/local/bin/
swap_guard.sh status
sudo swapoff -a && free -h                      # temporarily no swap
```

### C2. Build without swap → watch the OOM killer
```bash
cd ~/linux-devops-13-projects/project-05-flashcard-app/web
npm install --no-audit --no-fund
( NODE_OPTIONS=--max-old-space-size=900 npm run build ); echo "exit=$?"   # may print "Killed" and exit=137
swap_guard.sh oom-report "15 min ago"
```
> If it survives, run the API memory lab in C7 instead — the point is to *see* a 137 once.

### C3. Create swap the right way
```bash
sudo swap_guard.sh ensure 2G
sudo swap_guard.sh tune 10
cat /proc/swaps; grep swap /etc/fstab; sysctl vm.swappiness
systemctl list-units --type swap                 # swapfile.swap generated from fstab
```

### C4. Build again (it succeeds, slower but alive)
```bash
cd ~/linux-devops-13-projects/project-05-flashcard-app/web
( NODE_OPTIONS=--max-old-space-size=384 npm run build ); echo "exit=$?"     # exit=0
# second terminal during the build:
watch -n1 'free -m; cat /proc/pressure/memory'
cd ../api && npm install --no-audit --no-fund && npm run build
```

### C5. Install
```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group flashcards
sudo install -d -m 0755 -o root -g flashcards /opt/flashcards /opt/flashcards/web
sudo install -d -m 0750 -o root -g flashcards /etc/flashcards
cd ~/linux-devops-13-projects/project-05-flashcard-app
sudo rsync -a --delete web/dist/ /opt/flashcards/web/dist/
sudo rsync -a --delete --exclude src api/ /opt/flashcards/api/
( cd /opt/flashcards/api && sudo npm prune --omit=dev )
sudo chown -R root:flashcards /opt/flashcards && sudo chmod -R u=rwX,g=rX,o=rX /opt/flashcards
sudo cp .env.example /etc/flashcards/flashcards.env && sudo nano /etc/flashcards/flashcards.env
sudo chown root:flashcards /etc/flashcards/flashcards.env && sudo chmod 640 /etc/flashcards/flashcards.env
sudo systemd-run --wait --pipe --uid=flashcards --gid=flashcards \
     -p EnvironmentFile=/etc/flashcards/flashcards.env -p WorkingDirectory=/opt/flashcards/api \
     /usr/bin/node dist/migrate.js
sudo cp deploy/flashcards.service /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl enable --now flashcards
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy
curl -s http://127.0.0.1:5005/api/health | jq
```

### C6. Inspect memory accounting
```bash
systemctl show -p MemoryCurrent,MemoryPeak,MemoryHigh,MemoryMax flashcards
cat /sys/fs/cgroup/system.slice/flashcards.service/memory.events
cat /proc/$(systemctl show -p MainPID --value flashcards)/oom_score_adj     # 300
swap_guard.sh status
```

### C7. Provoke a cgroup OOM kill safely
```bash
sudo systemctl edit flashcards        # add:  [Service]  Environment=ENABLE_MEMORY_LAB=1
sudo systemctl restart flashcards
curl -s -X POST 'http://127.0.0.1:5005/api/lab/allocate?mb=60' ; echo
curl -s -X POST 'http://127.0.0.1:5005/api/lab/allocate?mb=200'; echo     # connection reset
systemctl status flashcards --no-pager | grep -E 'Active|Main PID|status='
journalctl -k -g 'memory cgroup out of memory' -n 3 --no-pager
grep oom_kill /sys/fs/cgroup/system.slice/flashcards.service/memory.events
sudo systemctl revert flashcards && sudo systemctl restart flashcards        # remove the lab override
```
Note: `Buffer.alloc` lives *outside* the V8 heap, so `--max-old-space-size` does not stop it — only the cgroup does.

### C8. Continuous guard
```bash
sudo tee /etc/systemd/system/swap-guard.service >/dev/null <<'EOF'
[Unit]
Description=swap_guard memory watcher
[Service]
ExecStart=/usr/local/bin/swap_guard.sh watch --interval 30 --min-avail-mb 100 --max-swap-pct 80
Restart=always
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now swap-guard
journalctl -t swap_guard -f
```
Open `https://<EC2_IP>.sslip.io` 🧠

---

## Part D — Break-Fix Drills

### Drill 1 — "npm run build: Killed" (exit 137)
**Break:** `sudo swapoff -a`, then build the web app with `NODE_OPTIONS=--max-old-space-size=900`.
**Diagnose:** `echo $?` → 137; `swap_guard.sh oom-report "10 min ago"` → `Killed process … (node)`; `free -h` shows Swap 0.
**Fix:** `sudo swapon -a` (fstab) or `sudo swap_guard.sh ensure 2G`; lower `--max-old-space-size` to 384. **Lesson:** 137 = SIGKILL = almost always memory.

### Drill 2 — Swap disappears after reboot
**Break:** `sudo sed -i.bak '/swapfile/d' /etc/fstab && sudo reboot`.
**Symptom:** `swapon --show` empty after boot; builds die again.
**Diagnose:** `grep swap /etc/fstab` → nothing; `systemctl list-units --type swap` → nothing.
**Fix:** `sudo swap_guard.sh ensure 2G` (re-adds the fstab line and verifies with `findmnt --verify`). **Lesson:** `swapon` is runtime only; persistence lives in `/etc/fstab`.

### Drill 3 — API restarts every few minutes with `status=9/KILL`
**Break:** set `MemoryMax=60M` via `sudo systemctl edit flashcards`, restart, browse the app.
**Symptom:** intermittent 502s; `systemctl status` shows `Result: oom-kill`; restart counter climbs.
**Diagnose:**
```bash
systemctl show -p NRestarts,Result,MemoryPeak flashcards
grep oom_kill /sys/fs/cgroup/system.slice/flashcards.service/memory.events
journalctl -u flashcards -g 'Main process exited' -n 5
```
**Fix:** `sudo systemctl revert flashcards && sudo systemctl daemon-reload && sudo systemctl restart flashcards`. Size limits from **observed** `MemoryPeak` + 30–50 % headroom.

**Bonus — Supabase "prepared statement does not exist":** set `prepare: true` in `db.ts`, rebuild, and hammer the API: errors appear because the transaction pooler hands your next query to a different backend connection. That's why the pooler needs `prepare: false`.

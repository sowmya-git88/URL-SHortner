# Project 09 — Markdown Blog · GUIDEBOOK

**Stack:** Astro (static build) · Rust Actix-web · Cloudflare D1 (SQLite over REST) + R2 (S3 API, SigV4) · Caddy
**Linux focus:** block devices & filesystems (`lsblk`, `df`, `du`, inodes), symlinks (`ln -s`) for releases, `cron` (`crontab`, `/etc/cron.d`), Fail2Ban, log-based intrusion prevention
**Script:** `scripts/disk_cleanup.sh`
**RAM budget:** Rust binary ≈ 8–15 MB RSS (!) · build happens **off-box** (GitHub Actions)

---

## Part A — Concepts to Learn First

### A1. From disk to file: the storage stack
```
 EBS volume (network block device)  →  /dev/nvme0n1            (lsblk: TYPE disk)
   └─ partition                      →  /dev/nvme0n1p1          (TYPE part)
        └─ filesystem (ext4)         →  mounted at /            (findmnt /, df -hT /)
             └─ directories & files  →  /var/log/…              (du, ls)
```
* `lsblk` = the **device tree** (disks, partitions, mount points). Nitro instances (t3) show **NVMe** names; older Xen (t2) show `/dev/xvda`.
* `df -h` = **filesystem** capacity: size/used/avail per mount. `df -i` = **inodes** (one per file; you can run out of inodes with free space left — millions of tiny files).
* `du -sh dir` = sum of the sizes of files *under a directory*. `du -xh --max-depth=1 / | sort -h` finds the hog. `-x` stays on one filesystem.
* **`df` and `du` disagree?** A deleted file that a process still holds open keeps using space (`df` counts it, `du` can't see it). Find with `lsof +L1` or `find /proc/*/fd -lname '*(deleted)'`; fix by restarting that process (classic: a huge log deleted with `rm` while the app still writes).
* Ext4 reserves ~5 % for root, so `Use%` can show 100 % while root still writes.

### A2. Links
* **Hard link** (`ln a b`): a second name for the **same inode**; same filesystem only; deleting one name keeps the data.
* **Symbolic link** (`ln -s target name`): a tiny file containing a *path*; can cross filesystems, can dangle.
* **Release pattern:** `/opt/mdblog/web/releases/20250131-1015/` … and `current → releases/20250131-1015`. Deploy = upload a new dir + **atomically swap the symlink**: `ln -sfn new current.tmp && mv -Tf current.tmp current` (`rename(2)` is atomic, so Caddy never sees a half-updated site). Rollback = point it back.

### A3. cron
* The **cron daemon** wakes every minute and checks: user crontabs (`crontab -e`, stored in `/var/spool/cron/crontabs/`), system crontab `/etc/crontab`, and `/etc/cron.d/*` (both with an extra **user** column), plus `/etc/cron.{hourly,daily,weekly}/` scripts (run by `run-parts`).
* Format: `m h dom mon dow [user] command`. `*/15 * * * *` = every 15 min. Test expressions at crontab.guru.
* Cron runs with a **minimal environment** (`PATH=/usr/bin:/bin`, no `~/.bashrc`) → use absolute paths or set `PATH=` at the top, redirect output (`>> log 2>&1`) or it's mailed/discarded, and remember `%` is special (escape as `\%`).
* `/etc/cron.d` filenames must not contain dots (`run-parts` naming rules) → `mdblog-maintenance`, not `mdblog.cron`.
* Logs: `journalctl -u cron`.
* systemd timers (Project 03) are the modern alternative; cron is still everywhere, so know both.

### A4. Fail2Ban
A daemon that **tails logs**, matches lines with regexes (**filters**), counts failures per IP within `findtime`, and when `maxretry` is reached runs an **action** (here: add the IP to an **nftables** set that drops its packets) for `bantime`.
* **jail** = filter + log source + action + thresholds. Config in `/etc/fail2ban/jail.d/*.local` (never edit `jail.conf`).
* Our Rust API writes `… mdblog auth failure from <IP> path=…` to `/var/log/mdblog/auth.log` on every bad admin token; the custom filter's `<HOST>` placeholder captures the IP.
* Because the API sits behind Caddy, the IP is taken from `X-Forwarded-For` — otherwise you'd ban `127.0.0.1` (i.e. nothing, it's in `ignoreip`) or yourself.
* Test a filter: `fail2ban-regex /var/log/mdblog/auth.log /etc/fail2ban/filter.d/mdblog-auth.conf`.
* Status/unban: `fail2ban-client status mdblog-auth`, `fail2ban-client set mdblog-auth unbanip 1.2.3.4`.

### A5. Why build Rust off-box
`cargo build --release` for Actix + reqwest/rustls peaks well above 1 GB RAM and takes a long time on 2 vCPU credits. The binary is self-contained, so: build in **GitHub Actions** (`.github/workflows/project-09-build.yml`, Ubuntu 24.04 runner = same glibc as EC2) or on your laptop, then `scp` it. Running it costs ~10 MB.

### A6. Cloudflare D1 & R2 from a normal server
* **D1** is SQLite managed by Cloudflare. Outside Workers you reach it via the **REST API** (`POST …/d1/database/{id}/query` with `{"sql": "...", "params": [...]}` and a Bearer API token). Each call is an HTTPS round-trip — fine for a blog.
* **R2** is S3-compatible object storage with **no egress fees**. Requests are authenticated with **AWS Signature V4**: the client hashes a canonical form of the request and HMAC-signs it with a key derived from the secret + date + region (`auto`) + service (`s3`). See `api/src/r2.rs` — 60 lines, no SDK.
* We **cache** fetched images on local disk (`/var/cache/mdblog/media`) → fewer R2 operations, faster responses — and a directory that `disk_cleanup.sh` must keep in check (FHS: `/var/cache` = deletable, rebuildable data).

### A7. Bash concepts in `disk_cleanup.sh`
`df -P` (POSIX one-line output, safe to parse), `awk 'NR==2 {gsub("%","",$5)}'`, `find -xdev -mtime/-atime -delete` (age-based deletion staying on one FS), `find -printf '%T@ %p'` + `sort -rn` (newest first), `readlink -f` (resolve symlink), `flock -n` on fd 9 (no overlapping cron runs), threshold logic with meaningful exit codes, `logger` to syslog.

---

## Part B — Architecture & Request Flow

```
 Browser
 https://<IP>.sslip.io
     │
     ▼
 ┌─────────────────────────┐  /api/*   ┌──────────────────────────────────┐  HTTPS REST (Bearer)  ┌──────────────────┐
 │ Caddy :443              │─────────▶ │ /opt/mdblog/bin/mdblog (Actix)   │─────────────────────▶ │ Cloudflare D1    │
 │ /  → /opt/mdblog/web/   │ :5009     │  User=mdblog · MemoryMax=80M     │                       │ posts (SQLite)   │
 │      current ──symlink──┼─┐         │  /api/media/{key}:                │  S3 API + SigV4       ├──────────────────┤
 └─────────────────────────┘ │         │   disk cache HIT → serve          │─────────────────────▶ │ Cloudflare R2    │
                             │         │   MISS → R2 GET → write cache     │                       │ mdblog-media     │
          releases/20250131-1015/      │  bad token → /var/log/mdblog/auth.log                     └──────────────────┘
          releases/20250130-2200/      └───────────────┬──────────────────┘
                                                       │ tail
      /var/cache/mdblog/media  ◀── disk_cleanup.sh     ▼
      (cron.d every 15 min / daily)          Fail2Ban jail mdblog-auth → nftables drop <IP> for 2h
                                             Fail2Ban jail sshd (journald)
```

---

## Part C — Step-by-Step Manual Deployment Lab

### C1. Cloudflare resources (dashboard or `npx wrangler` on your laptop)
1. **D1:** Workers & Pages → D1 → *Create* `mdblog` → copy the **Database ID**. (Optional: `npx wrangler d1 execute mdblog --remote --file=db/schema.sql`; the API also applies it at startup.)
2. **API token:** My Profile → API Tokens → *Create custom token* → permission **Account → D1 → Edit**.
3. **R2:** create bucket `mdblog-media` → *Manage R2 API tokens* → Object Read & Write → copy Access Key ID + Secret.
4. Account ID from the dashboard sidebar.

### C2. Explore the disk first
```bash
sudo systemctl disable --now pm2-kanban 2>/dev/null || true
lsblk -f
findmnt /
df -hT; df -i /
sudo du -xh --max-depth=1 / 2>/dev/null | sort -h | tail
sudo du -sh /var/log/* 2>/dev/null | sort -h | tail -5
journalctl --disk-usage
```

### C3. Get the binary + site (built by GitHub Actions)
```bash
# GitHub → Actions → project-09-build → latest run → download artifact "mdblog-<sha>" (zip), then on your laptop:
scp mdblog-*.zip devops:/tmp/
# on EC2:
cd /tmp && unzip -o mdblog-*.zip -d mdblog-artifact && cd mdblog-artifact && sha256sum -c SHA256SUMS
```
*Alternative (laptop with Rust):* `cargo build --release --manifest-path project-09-markdown-blog/api/Cargo.toml` and `scp` the binary.

### C4. User, directories, binary, config
```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group mdblog
sudo install -d -m 0755 /opt/mdblog /opt/mdblog/bin /opt/mdblog/web /opt/mdblog/web/releases
sudo install -d -m 0750 -o root -g mdblog /etc/mdblog
sudo install -d -m 0750 -o mdblog -g mdblog /var/cache/mdblog /var/cache/mdblog/media /var/log/mdblog
sudo install -m 0755 /tmp/mdblog-artifact/mdblog /opt/mdblog/bin/mdblog
cd ~/linux-devops-13-projects/project-09-markdown-blog
sudo cp .env.example /etc/mdblog/mdblog.env && sudo nano /etc/mdblog/mdblog.env   # ADMIN_TOKEN: openssl rand -hex 32
sudo chown root:mdblog /etc/mdblog/mdblog.env && sudo chmod 640 /etc/mdblog/mdblog.env
sudo cp deploy/mdblog.service /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl enable --now mdblog
journalctl -u mdblog -n 10 --no-pager                  # "seeded first post", "listening on 127.0.0.1:5009"
ps -o pid,rss,cmd -C mdblog                            # look at that RSS
curl -s http://127.0.0.1:5009/api/health | jq
```

### C5. Static site releases with an atomic symlink swap
```bash
REL=/opt/mdblog/web/releases/$(date -u +%Y%m%d-%H%M%S)
sudo mkdir -p "$REL" && sudo tar -C "$REL" -xzf /tmp/mdblog-artifact/web-dist.tar.gz
sudo ln -sfn "$REL" /opt/mdblog/web/current.tmp && sudo mv -Tf /opt/mdblog/web/current.tmp /opt/mdblog/web/current
ls -l /opt/mdblog/web/                                 # current -> releases/2025…
readlink -f /opt/mdblog/web/current
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy
```
Deploy the same artifact twice more (new timestamps) so there are releases to clean up later.

### C6. Fail2Ban
```bash
sudo apt-get install -y fail2ban python3-systemd
sudo cp deploy/fail2ban/mdblog-auth.conf /etc/fail2ban/filter.d/
sudo cp deploy/fail2ban/jail.local /etc/fail2ban/jail.d/devops-lab.local
sudo nano /etc/fail2ban/jail.d/devops-lab.local       # add YOUR public IP to ignoreip
sudo systemctl enable --now fail2ban && sudo systemctl restart fail2ban
sudo fail2ban-client status
# generate failures from ANOTHER IP (phone hotspot / cloud shell), not your ignoreip:
for i in $(seq 1 6); do curl -s -o /dev/null -w '%{http_code}\n' -X POST https://<IP>.sslip.io/api/posts -H 'Authorization: Bearer wrong'; done
sudo tail -n 3 /var/log/mdblog/auth.log
sudo fail2ban-regex /var/log/mdblog/auth.log /etc/fail2ban/filter.d/mdblog-auth.conf | tail -5
sudo fail2ban-client status mdblog-auth
sudo nft list ruleset | grep -A3 f2b
```

### C7. Disk cleanup + cron
```bash
sudo install -m 0755 scripts/disk_cleanup.sh /usr/local/bin/
sudo disk_cleanup.sh --threshold 0 --dry-run          # forces a full dry-run report
sudo disk_cleanup.sh --force --keep-releases 1
sudo cp deploy/cron-mdblog /etc/cron.d/mdblog-maintenance && sudo chmod 644 /etc/cron.d/mdblog-maintenance
sudo cp deploy/logrotate-mdblog /etc/logrotate.d/mdblog
grep -h CRON /var/log/syslog | tail -3 || journalctl -u cron -n 5 --no-pager
```

### C8. Publish a post
Open `https://<IP>.sslip.io/admin/`, paste your `ADMIN_TOKEN`, upload a cover image (→ R2), write Markdown, publish. Reload the post twice and compare `X-Cache: MISS` then `HIT`: `curl -sI https://<IP>.sslip.io/api/media/<key> | grep -i x-cache`.

---

## Part D — Break-Fix Drills

### Drill 1 — "No space left on device" but `du` finds nothing
**Break:**
```bash
sudo fallocate -l 3G /var/log/mdblog/huge.log
sudo bash -c 'exec 3>>/var/log/mdblog/huge.log; exec sleep 3600' &     # a process holding it open
sudo rm /var/log/mdblog/huge.log
```
**Symptom:** `df -h /` still shows the 3 GB used; `du -sh /var/log/mdblog` is tiny.
**Diagnose:** `sudo lsof +L1 | head` or `sudo find /proc/*/fd -lname '*(deleted)' -ls 2>/dev/null`; `disk_cleanup.sh --dry-run --force` reports it.
**Fix:** restart/kill the holder (`sudo pkill -f 'sleep 3600'`) → space returns. Prevention: rotate with `logrotate`; to empty a live log use `truncate -s 0 file`, never `rm`.

### Drill 2 — Broken site after a deploy (dangling symlink)
**Break:** `sudo ln -sfn /opt/mdblog/web/releases/does-not-exist /opt/mdblog/web/current`.
**Symptom:** the homepage returns 404; the API still works.
**Diagnose:** `ls -l /opt/mdblog/web/current` (red/blinking in `ls --color`), `readlink -e /opt/mdblog/web/current || echo dangling`, `sudo tail /var/log/caddy/mdblog.access.log | jq .status`.
**Fix:** `sudo ln -sfn "$(ls -1dt /opt/mdblog/web/releases/*/ | head -1)" /opt/mdblog/web/current`. **Lesson:** atomic swaps + always keep the previous release for instant rollback.

### Drill 3 — You banned yourself / cron job never runs
**Break A:** remove your IP from `ignoreip`, trigger 5 bad-token requests from your laptop.
**Symptom A:** site and SSH time out from your network.
**Fix A:** EC2 *Instance Connect* or Session Manager → `sudo fail2ban-client set mdblog-auth unbanip <your-ip>` (or `unban --all`), re-add `ignoreip`.
**Break B:** `sudo cp deploy/cron-mdblog /etc/cron.d/mdblog.cron`.
**Symptom B:** nothing in `/var/log/disk_cleanup.log`.
**Diagnose B:** `journalctl -u cron | grep -i mdblog` (nothing) → `run-parts --test /etc/cron.d` ignores names with dots; also check: file owned by root, mode 644, ends with a newline, has the **user** column.
**Fix B:** rename to `/etc/cron.d/mdblog-maintenance`.

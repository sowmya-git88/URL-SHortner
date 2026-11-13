# Project 01 — URL Shortener · GUIDEBOOK

**Stack:** Static HTML/JS · Python Flask + Gunicorn · SQLite · Caddy
**Linux focus:** Filesystem Hierarchy Standard (FHS), `apt`, SSH key hardening, `ufw`
**Script:** `scripts/setup_server.sh`
**RAM budget:** Gunicorn 2 workers ≈ 50–70 MB · Caddy ≈ 25 MB

---

## Part A — Concepts to Learn First

### A1. Linux is "everything is a file in one tree"
There are no drive letters. Everything hangs off `/`. The **FHS** (Filesystem Hierarchy Standard) says *what kind of file goes where*, so any admin can find things on any Linux box:

| Directory | Meaning | In this project |
|-----------|---------|-----------------|
| `/opt` | **o**ptional, self-contained add-on software (not managed by apt) | `/opt/urlshort/app`, `/opt/urlshort/venv`, `/opt/urlshort/frontend` |
| `/etc` | host-specific **configuration** (text, edited by admins) | `/etc/urlshort/urlshort.env`, `/etc/caddy/Caddyfile`, `/etc/systemd/system/urlshort.service` |
| `/var` | **variable** data that grows/changes at runtime | `/var/lib/urlshort/urlshort.db` (state), `/var/log/caddy/` (logs) |
| `/usr` | read-only programs installed by the package manager | `/usr/bin/caddy`, `/usr/bin/python3` |
| `/home` | users' personal files | `/home/ubuntu` — **never** run production apps from here |
| `/tmp` | throw-away files, cleared on reboot | — |
| `/run` | runtime state (PID files, sockets), a RAM filesystem | used in Project 06 |

**Why it matters:** separating *code* (`/opt`, read-only to the app), *config* (`/etc`, root-owned) and *state* (`/var/lib`, writable by the app) means a compromised app process cannot rewrite its own code or config. Backups also become simple: back up `/etc/urlshort` + `/var/lib/urlshort`; code comes from Git.

### A2. Users, ownership and permission bits (the 60-second version)
Every file has an **owner user**, an **owner group**, and three permission triplets: `u`ser `g`roup `o`thers, each `r`(4) `w`(2) `x`(1).

```
-rw-r----- 1 root urlshort  210 urlshort.env
 │└┬┘└┬┘└┬┘   │    │
 │ u  g  o   owner group
 └ file type (- file, d directory, l symlink)
```
`0640` = owner `rw` (6), group `r` (4), others nothing (0). Root edits it; the `urlshort` service *reads* it through its group; nobody else can see the secrets.

On **directories**, `x` means "may enter / traverse". Caddy (user `caddy`) must traverse `/opt`, `/opt/urlshort`, `/opt/urlshort/frontend` (`x` on each) and read the files (`r`). That is why the frontend dir is `755` and files `644`.

The app runs as a **system user** (`useradd --system`): no password, no login shell (`/usr/sbin/nologin`), UID < 1000. If the app is hacked, the attacker gets a powerless user, not `ubuntu` (which has sudo).

### A3. `apt` — how packages actually get installed
* `/etc/apt/sources.list.d/*.sources|*.list` → which repositories to trust.
* `apt-get update` downloads the **package index** (catalogue) — it installs nothing.
* `apt-get install X` resolves dependencies, downloads `.deb` files into `/var/cache/apt/archives`, and `dpkg` unpacks them into `/usr`, `/etc`, runs post-install scripts (e.g. creating the `caddy` user and enabling `caddy.service`).
* Third-party repos (Caddy) are trusted via a **GPG key** stored in `/usr/share/keyrings/` and referenced by `signed-by=` — so a key for Caddy cannot be used to sign fake Ubuntu packages.
* `DEBIAN_FRONTEND=noninteractive` stops dialogs from hanging scripts; `--force-confold` keeps your edited config files during upgrades.

### A4. SSH key authentication & hardening
Password login is brute-forced by bots within minutes of an IP going live. **Public-key auth**: your laptop holds the *private* key (`.pem`, mode `400`); the server holds the *public* key in `~ubuntu/.ssh/authorized_keys`. The server sends a challenge only the private key can sign; the key never crosses the network.

Ubuntu 24.04's `/etc/ssh/sshd_config` contains `Include /etc/ssh/sshd_config.d/*.conf` **at the top**, and for `sshd` the **first** value it reads for a keyword wins. So a drop-in file overrides the defaults without editing the vendor file (clean upgrades).

Golden rules: (1) **`sshd -t`** validates syntax before reload; (2) **reload, not restart** — existing sessions survive; (3) **keep a second session open** while testing.

### A5. Firewalls: Security Group *and* `ufw`
Two layers: the AWS **Security Group** filters traffic before it reaches the VM; **`ufw`** (a friendly front-end for the kernel's netfilter/nftables) filters inside the VM. Defence in depth: if someone opens port 5001 in the SG by mistake, `ufw` still drops it — and the app binds `127.0.0.1` anyway, so it is not reachable even with both firewalls open.

`ufw default deny incoming` + explicit `allow` rules = allow-list model. Always `ufw allow OpenSSH` **before** `ufw enable`.

### A6. Ports, binding and `127.0.0.1`
A server process calls `bind(ip, port)`. `0.0.0.0:5001` = every interface (public!). `127.0.0.1:5001` = loopback only — reachable only from inside the box. Ports < 1024 need root or `CAP_NET_BIND_SERVICE`, which is why **Caddy** (which has that capability via its systemd unit) owns 80/443 and the app uses 5001.

`ss -tulpn` = **s**ocket **s**tatistics: **t**cp, **u**dp, **l**istening, **p**rocess, **n**umeric.

### A7. Reverse proxy & request routing (Caddy, gently)
Caddy receives every request on 80/443 and decides by path:
* `/api/*` and `/s/*` → `reverse_proxy 127.0.0.1:5001` (Gunicorn)
* everything else → `file_server` from `/opt/urlshort/frontend`

Caddy adds `X-Forwarded-For`, `X-Forwarded-Proto` and keeps the `Host` header. Flask's `ProxyFix(x_for=1, x_proto=1, x_host=1)` trusts exactly **one** proxy hop, so `request.host_url` becomes `https://<IP>.sslip.io/` and the short links it generates are correct.

**sslip.io:** a public DNS server that answers `1.2.3.4.sslip.io → 1.2.3.4`. That gives you a real hostname, so Let's Encrypt can issue a certificate via the HTTP-01 challenge on port 80. Raw IPs get plain HTTP (`http://{$EC2_IP}` block).

### A8. Gunicorn, WSGI and why not `flask run`
`flask run` is a single-threaded dev server. **Gunicorn** is a pre-fork WSGI server: a master process forks N worker processes; if one crashes the master replaces it. `--workers 2` on 1 vCPU / 1 GB is the sweet spot. Each worker opens its own SQLite connection.

### A9. SQLite on a server
One file, no server process, 0 MB extra RAM. `PRAGMA journal_mode=WAL` lets readers and one writer work concurrently (it creates `-wal` and `-shm` files next to the DB — the **directory** must be writable by the app user, not just the file).

### A10. Bash concepts used in `setup_server.sh`
| Construct | Why |
|-----------|-----|
| `#!/usr/bin/env bash` | finds bash on `$PATH` — portable shebang |
| `set -e` | exit on any failing command |
| `set -u` | using an unset variable is an error (catches typos like `$SWAPSIZE`) |
| `set -o pipefail` | a pipeline fails if *any* part fails, not just the last |
| `set -E` | functions inherit the `ERR` trap (without it, errors inside functions skip the trap) |
| `IFS=$'\n\t'` | word-split only on newlines/tabs, not spaces |
| `trap 'on_error ${LINENO}' ERR` | prints the failing line number before exiting |
| `run()` wrapper | implements `--dry-run` once instead of `if` around every command |
| `[[ -s file ]]` | file exists **and** is non-empty |
| `cmp -s a b` | silent compare → idempotency (only change when different) |
| heredoc `<<'EOF'` | quoted delimiter = no `$var` expansion inside |
| `install -m 0644 -o root -g root` | copy + chmod + chown atomically |

---

## Part B — Architecture & Request Flow

```
                    ┌──────────────────────── AWS Security Group (22 my-IP, 80, 443) ───────────────────────┐
 Browser            │  EC2 t3.micro · Ubuntu 24.04 · ufw (deny in, allow 22/80/443)                          │
 https://1.2.3.4.sslip.io                                                                                    │
   │  DNS: sslip.io answers 1.2.3.4                                                                          │
   ▼                                                                                                         │
 ┌──────────────────────────┐   /api/*, /s/*    ┌───────────────────────────────┐   sqlite3   ┌───────────────────────────┐
 │ Caddy  :80 :443          │ ────────────────▶ │ Gunicorn master (urlshort)    │ ──────────▶ │ /var/lib/urlshort/        │
 │ user: caddy              │  127.0.0.1:5001   │  ├─ worker 1 (Flask app)      │             │   urlshort.db (+wal,shm)  │
 │ TLS: Let's Encrypt       │                   │  └─ worker 2 (Flask app)      │             │ owner urlshort:urlshort   │
 │ /etc/caddy/Caddyfile     │                   │ code: /opt/urlshort/app (ro)  │             └───────────────────────────┘
 └──────────┬───────────────┘                   │ env : /etc/urlshort/*.env     │
            │  everything else                  └───────────────────────────────┘
            ▼
 /opt/urlshort/frontend/{index.html,app.js,style.css}   (file_server)
```

Redirect flow: `GET /s/gh` → Caddy → Flask → `UPDATE clicks` + `INSERT click_log` → `302 Location: https://github.com`.

---

## Part C — Step-by-Step Manual Deployment Lab

> All commands run on the EC2 box as `ubuntu`. `EC2_IP` is your public IP.

### C1. Harden the server (once per box)
```bash
cd ~/linux-devops-13-projects/project-01-url-shortener
sudo bash scripts/setup_server.sh --dry-run            # read what it will do
sudo bash scripts/setup_server.sh --swap-size 2G --with-caddy
# open a NEW terminal and confirm you can still SSH in:
ssh devops 'echo still-in'
```

### C2. Explore the FHS before creating anything
```bash
ls -ld /opt /etc /var/lib /var/log
cat /etc/os-release
dpkg -L caddy | head -20          # files the caddy package installed
apt-cache policy caddy            # which repo it came from
systemctl cat caddy               # unit file + our drop-in override
```

### C3. Dedicated system user and directories
```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group urlshort
id urlshort
sudo install -d -m 0755 -o root     -g urlshort /opt/urlshort
sudo install -d -m 0750 -o root     -g urlshort /etc/urlshort
sudo install -d -m 0750 -o urlshort -g urlshort /var/lib/urlshort
```

### C4. Copy code (root-owned, read-only to the app)
```bash
sudo cp -r app frontend /opt/urlshort/
sudo chown -R root:urlshort /opt/urlshort/app
sudo chmod -R u=rwX,g=rX,o=  /opt/urlshort/app      # app code: group read, others nothing
sudo chown -R root:root /opt/urlshort/frontend
sudo chmod -R u=rwX,go=rX    /opt/urlshort/frontend  # caddy must read it (others r)
namei -l /opt/urlshort/frontend/index.html           # shows permission on every path component
```

### C5. Python virtualenv
```bash
sudo python3 -m venv /opt/urlshort/venv
sudo /opt/urlshort/venv/bin/pip install --no-cache-dir -r /opt/urlshort/app/requirements.txt
sudo chown -R root:urlshort /opt/urlshort/venv
```

### C6. Configuration file
```bash
sudo cp .env.example /etc/urlshort/urlshort.env
sudo chown root:urlshort /etc/urlshort/urlshort.env
sudo chmod 0640 /etc/urlshort/urlshort.env
sudo -u urlshort cat /etc/urlshort/urlshort.env   # works (group read)
cat /etc/urlshort/urlshort.env                    # Permission denied as ubuntu → correct
```

### C7. Initialise + seed the database as the app user
```bash
cd /opt/urlshort/app
sudo -u urlshort env DB_PATH=/var/lib/urlshort/urlshort.db /opt/urlshort/venv/bin/flask --app app seed-db
sudo -u urlshort sqlite3 /var/lib/urlshort/urlshort.db 'SELECT code,target_url FROM links;'
ls -l /var/lib/urlshort/
```

### C8. systemd service
```bash
sudo cp ~/linux-devops-13-projects/project-01-url-shortener/deploy/urlshort.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now urlshort
systemctl status urlshort --no-pager
sudo ss -tulpn | grep -E ':5001|:80|:443'      # 5001 must show 127.0.0.1, not 0.0.0.0
curl -s http://127.0.0.1:5001/api/health | jq
```

### C9. Caddy
```bash
cat /etc/caddy/caddy.env                         # EC2_IP=x.x.x.x
sudo cp ~/linux-devops-13-projects/project-01-url-shortener/deploy/Caddyfile /etc/caddy/Caddyfile
sudo env $(sudo cat /etc/caddy/caddy.env) caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
sudo journalctl -u caddy -n 30 --no-pager        # look for "certificate obtained successfully"
```

### C10. Verify end-to-end
```bash
EC2_IP=$(curl -s https://checkip.amazonaws.com)
curl -s  http://$EC2_IP/api/health | jq
curl -s https://$EC2_IP.sslip.io/api/health | jq
curl -s -X POST https://$EC2_IP.sslip.io/api/links -H 'Content-Type: application/json' \
     -d '{"url":"https://www.kernel.org","code":"kernel"}' | jq
curl -sI https://$EC2_IP.sslip.io/s/kernel | grep -i location
sudo ufw status numbered
nc -zv $EC2_IP 5001 || echo "5001 not public — good"   # run from your laptop
```
Open `https://<EC2_IP>.sslip.io` in a browser. 🎉

---

## Part D — Break-Fix Drills

### Drill 1 — "502 Bad Gateway" after a reboot
**Break:** `sudo systemctl disable --now urlshort && sudo reboot`
**Symptom:** the page loads (static files) but every API call returns **502**.
**Diagnose:**
```bash
curl -si https://$EC2_IP.sslip.io/api/health | head -1     # HTTP/2 502
sudo journalctl -u caddy -n 20 | grep -i 'dial tcp'          # connection refused 127.0.0.1:5001
sudo ss -tlnp | grep 5001                                    # nothing listening
systemctl is-enabled urlshort                                # disabled
```
**Fix:** `sudo systemctl enable --now urlshort`. **Lesson:** `start` ≠ `enable`. 502 = proxy is fine, upstream is dead.

### Drill 2 — "attempt to write a readonly database"
**Break:** `sudo chown root:root /var/lib/urlshort && sudo systemctl restart urlshort`
**Symptom:** GET works, POST `/api/links` → 500. Logs show `sqlite3.OperationalError: attempt to write a readonly database` or `unable to open database file`.
**Diagnose:**
```bash
sudo journalctl -u urlshort -p err -n 20
namei -l /var/lib/urlshort/urlshort.db
sudo -u urlshort touch /var/lib/urlshort/probe     # Permission denied → proof
```
**Fix:** `sudo chown -R urlshort:urlshort /var/lib/urlshort && sudo chmod 750 /var/lib/urlshort`. **Lesson:** WAL mode needs to create `-wal`/`-shm` files, so the **directory** must be writable, not just the `.db`.

### Drill 3 — Locked out of SSH (prevented!)
**Break (in a safe way):** add `PasswordAuthentication maybe` to `/etc/ssh/sshd_config.d/99-hardening.conf`.
**Diagnose:** `sudo sshd -t` → `Bad configuration option` / `unsupported option` with file and line number.
**Fix:** remove the line, `sudo sshd -t && sudo systemctl reload ssh`.
**If you really are locked out:** EC2 console → *Connect* → **EC2 Instance Connect** or **Session Manager**, or stop instance → detach root volume → attach to a rescue instance → fix the file. **Lesson:** always `sshd -t` and keep a second session open.

**Bonus drill — Certificate never issues:** Caddy log says `timeout during connect` for the ACME challenge → Security Group missing port 80, or `ufw` blocks 80. Check `sudo ufw status` and the SG inbound rules.

# linux-devops-13-projects

A hands-on, **$0-budget** Linux + DevOps curriculum: 13 full-stack projects, each on a **different stack**, each teaching a **harder layer of Linux administration and Bash scripting**. Projects 01–10 run on a single **AWS Free Tier EC2 (1 GB RAM)** box. Projects 11–13 are heavier capstones that run on your **local Linux laptop** (Docker Compose, Prometheus/Grafana, k3s + Ansible).

> **Learning rule for every project: _Learn First, Perform Second._**
> Open `project-XX-*/GUIDEBOOK.md`, read **Part A (concepts)** and **Part B (architecture)** *before* typing a single command in **Part C (lab)**. Then break things on purpose with **Part D (drills)**.

---

## 1. Master Curriculum

| # | Project | Frontend | Backend | Database / Storage (free tier) | Proxy / TLS | Linux & Bash skills | Script | Runs on |
|---|---------|----------|---------|-------------------------------|-------------|---------------------|--------|---------|
| 01 | `project-01-url-shortener` | Static HTML/JS | Python Flask + Gunicorn | SQLite (local file) | Caddy | FHS (`/opt` `/etc` `/var`), `apt`, SSH key hardening, `ufw` | `setup_server.sh` | EC2 |
| 02 | `project-02-bookmark-manager` | HTMX | Go (single static binary) | Turso LibSQL | Caddy | users/groups, `nohup`, `jobs`/`fg`/`bg`, signals 15 vs 9, `htop` | `health_watch.sh` | EC2 |
| 03 | `project-03-habit-tracker` | Alpine.js | Node.js Express | MongoDB Atlas M0 | Caddy | hand-written systemd units, timers, `journalctl` filtering | `service_audit.sh` | EC2 |
| 04 | `project-04-expense-splitter` | Vanilla JS | Python FastAPI + Uvicorn | Neon Postgres | **Caddy deep-dive** | `/api/*` vs `/` routing, auto-HTTPS on `IP.sslip.io` | `deploy_fastapi.sh` | EC2 |
| 05 | `project-05-flashcard-app` | Svelte 5 (Vite) | Hono (TypeScript, Node) | Supabase Postgres | Caddy | swap, OOM killer, exit code 137, `free -h`, sysctl | `swap_guard.sh` | EC2 |
| 06 | `project-06-support-tickets` | Preact + htm (no build) | PHP 8.3 + PHP-FPM | Aiven Free MySQL | **Nginx + Certbot** | FPM pools, Unix sockets, DuckDNS, Let's Encrypt | `nginx_vhost.sh` | EC2 |
| 07 | `project-07-snippet-bin` | Vue 3 (CDN build) | Ruby Sinatra + Puma | Upstash Redis | Caddy | `grep` `awk` `sed` `cut` `sort` `uniq`, pipes, redirection | `log_analyzer.sh` | EC2 |
| 08 | `project-08-kanban-board` | SolidJS (Vite) | Deno 2 | CockroachDB (free Basic/Serverless) | Caddy | PM2, `pm2 startup`, `logrotate`, OpenSSL encryption | `backup_env.sh` | EC2 |
| 09 | `project-09-markdown-blog` | Astro (static) | Rust Actix-web | Cloudflare D1 + R2 | Caddy | `df` `du` `lsblk`, symlinks, `cron`, Fail2Ban | `disk_cleanup.sh` | EC2 |
| 10 | `project-10-status-dashboard` | React (Bun bundler) | Bun | Neon Postgres + Upstash Redis | Caddy (blue/green) | GitHub Actions over SSH, `visudo`, zero-downtime + rollback | `zero_downtime_deploy.sh` | EC2 |
| 11 | `project-11-docker-saas` | Next.js 14 | NestJS | Postgres + Redis + MinIO (containers) | Caddy container | multi-stage Dockerfiles, Compose networks/volumes/healthchecks | `docker_health.sh` | Laptop |
| 12 | `project-12-observability-store` | React (Vite) | Spring Boot 3 / Java 21 | Postgres + Kafka (KRaft) | Nginx container | Prometheus, Grafana, Node Exporter, alert rules | `alert_test.sh` | Laptop |
| 13 | `project-13-k3s-microservices` | React (Vite) | Go API + Python worker | Postgres StatefulSet | Traefik Ingress | k3s manifests, probes, HPA, Ansible provisioning | `cluster_bootstrap.sh` | Laptop |

**Port map (EC2, all bound to `127.0.0.1` only — never public):**
`5001` P01 · `5002` P02 · `5003` P03 · `5004` P04 · `5005` P05 · PHP-FPM socket P06 · `5007` P07 · `5008` P08 · `5009` P09 · `5010/5011` P10 (blue/green).

### Repository layout convention (every project)

```
project-XX-name/
├── GUIDEBOOK.md        # Part A concepts · Part B architecture · Part C lab · Part D drills
├── .env.example        # copy to /etc/<app>/<app>.env on the server (never commit the real one)
├── deploy/             # Caddyfile / nginx conf, systemd units, logrotate, sudoers ...
├── scripts/*.sh        # the project's production Bash script
└── <frontend>/ <backend>/ <db>/   # full runnable code, schema, seed
```

### Server-side layout convention (Linux FHS)

| Path | What lives there | Owner |
|------|------------------|-------|
| `/opt/<app>/` | application code, venvs, binaries, releases | `root:<app>` (code is read-only to the app user) |
| `/etc/<app>/<app>.env` | secrets & config | `root:<app>` mode `0640` |
| `/var/lib/<app>/` | mutable state (SQLite, uploads) | `<app>:<app>` mode `0750` |
| `/var/log/<app>/` | app log files (if not using journald) | `<app>:<app>` |
| `/var/cache/<app>/` | rebuildable cache | `<app>:<app>` |
| `/etc/systemd/system/<app>.service` | service unit | `root:root` `0644` |
| `/etc/caddy/Caddyfile` | **the active project's** proxy config | `root:caddy` |

---

## 2. One edge proxy, one active project (read this once)

Only **one process can bind ports 80/443**. Projects 01–05 and 07–10 use **Caddy**; Project 06 uses **Nginx + Certbot**. The workflow is:

1. Each project ships a complete `deploy/Caddyfile` → you copy it over `/etc/caddy/Caddyfile`. That project becomes the "active" one at `http://<EC2_IP>` and `https://<EC2_IP>.sslip.io`.
2. Before deploying the next project, **stop the previous app** to give RAM back: `sudo systemctl disable --now <previous>.service`.
3. Switching to P06 (Nginx): `sudo systemctl disable --now caddy && sudo systemctl enable --now nginx`. Switching back: the reverse.

> **Want several projects live at once?** sslip.io resolves *any* prefix, e.g. `p01.<EC2_IP>.sslip.io` → `<EC2_IP>`. Put several site blocks (each with its own prefix host) into one Caddyfile. Only do this after Project 05 (swap), and watch `free -h`.

---

## 3. EC2 Free Tier: launch + initial hardening + 2 GB swap

### 3.1 Launch the instance (AWS console)
1. **AMI:** Ubuntu Server 24.04 LTS (x86_64). **Type:** `t3.micro` (or `t2.micro`) — check which one your account's free tier covers.
2. **Key pair:** create `ec2-devops` (ED25519, `.pem`). On your laptop: `chmod 400 ~/Downloads/ec2-devops.pem && mv ~/Downloads/ec2-devops.pem ~/.ssh/`.
3. **Storage:** 15 GB gp3 (well within the free 30 GB EBS allowance).
4. **Security group `sg-devops-lab`:**
   | Type | Port | Source |
   |------|------|--------|
   | SSH | 22 | **My IP** only |
   | HTTP | 80 | 0.0.0.0/0 (needed for ACME HTTP-01 challenges) |
   | HTTPS | 443 | 0.0.0.0/0 |
5. **Billing guardrail:** in *Billing → Budgets* create a **$1 zero-spend budget** with email alerts. Note: AWS changed the free-tier model for accounts created on/after **15 July 2025** (credit-based plan) — read your account's Free Tier page. Public IPv4 addresses can be billable; **stop** (don't just disconnect) the instance when you are not using it, and remember the public IP changes on stop/start unless you allocate an Elastic IP.

### 3.2 First login
```bash
ssh -i ~/.ssh/ec2-devops.pem ubuntu@<EC2_IP>
```
Optional `~/.ssh/config` on your laptop:
```
Host devops
    HostName <EC2_IP>
    User ubuntu
    IdentityFile ~/.ssh/ec2-devops.pem
    IdentitiesOnly yes
    ServerAliveInterval 60
```
Then just `ssh devops`.

### 3.3 Automated hardening (recommended)
```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/<YOUR_GITHUB_USER>/linux-devops-13-projects.git ~/linux-devops-13-projects
cd ~/linux-devops-13-projects/project-01-url-shortener
sudo bash scripts/setup_server.sh --swap-size 2G --with-caddy
```
The script (explained line-by-line in Project 01 Part A) does: full `apt` upgrade, base tooling, timezone, **2 GB swap**, `sysctl` tuning, SSH key-only hardening (validated with `sshd -t` *before* reload), `ufw` (22/80/443), unattended security upgrades, and installs Caddy.

### 3.4 Manual hardening (do it once by hand to understand it)
```bash
# 1) Patch everything
sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
sudo apt-get install -y ufw htop jq curl unzip ca-certificates unattended-upgrades

# 2) SSH: keys only, no root login (Ubuntu 24.04 reads /etc/ssh/sshd_config.d/*.conf)
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowUsers ubuntu
EOF
sudo sshd -t && sudo systemctl reload ssh     # -t = syntax test; NEVER reload without it
#   keep your current SSH session open and test a NEW session before logging out!

# 3) Firewall (allow SSH FIRST, then enable)
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp        # HTTP/3 (Caddy)
sudo ufw --force enable
sudo ufw status verbose

# 4) 2 GB swap file (the 1 GB box WILL OOM on builds without it)
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo -e 'vm.swappiness=10\nvm.vfs_cache_pressure=50' | sudo tee /etc/sysctl.d/99-swap.conf
sudo sysctl --system
free -h && swapon --show

# 5) Automatic security patches
sudo dpkg-reconfigure -f noninteractive unattended-upgrades
sudo timedatectl set-timezone UTC
```

### 3.5 Install Caddy (used by most projects)
```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy

# Give Caddy the EC2 IP as an environment variable used by every project's Caddyfile ({$EC2_IP})
EC2_IP=$(curl -s https://checkip.amazonaws.com)
echo "EC2_IP=${EC2_IP}" | sudo tee /etc/caddy/caddy.env
sudo mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironmentFile=/etc/caddy/caddy.env\n' | sudo tee /etc/systemd/system/caddy.service.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart caddy
```
> **If your public IP changes** (stop/start without Elastic IP): update `/etc/caddy/caddy.env` and `sudo systemctl restart caddy`.

---

## 4. GitHub repository workflow

### 4.1 First push (from your laptop)
```bash
cd linux-devops-13-projects
git init -b main
git add .
git commit -m "chore: bootstrap 13-project Linux/DevOps curriculum"
git remote add origin git@github.com:<YOUR_GITHUB_USER>/linux-devops-13-projects.git
git push -u origin main
```

### 4.2 Per-project branch flow
```bash
git switch -c p04/expense-splitter          # one branch per project lab
# ... make changes, fix drills, add notes to GUIDEBOOK.md ...
git add project-04-expense-splitter
git commit -m "feat(p04): add settle-up endpoint"
git push -u origin p04/expense-splitter     # open a PR, review your own diff, merge
```
Commit prefixes: `feat(pXX)`, `fix(pXX)`, `docs(pXX)`, `ops(pXX)`, `ci`.

### 4.3 Pull code onto EC2 with a read-only deploy key (no personal credentials on the server)
```bash
# on EC2
ssh-keygen -t ed25519 -f ~/.ssh/gh_deploy -N "" -C "ec2-deploy-key"
cat ~/.ssh/gh_deploy.pub     # GitHub → repo → Settings → Deploy keys → Add (read-only)
cat >> ~/.ssh/config <<'EOF'
Host github.com
    IdentityFile ~/.ssh/gh_deploy
    IdentitiesOnly yes
EOF
git clone git@github.com:<YOUR_GITHUB_USER>/linux-devops-13-projects.git ~/linux-devops-13-projects
cd ~/linux-devops-13-projects && git pull --ff-only     # every later update
```

### 4.4 Secrets hygiene
* Real values live **only** in `/etc/<app>/<app>.env` (mode `0640`, group = app user) or GitHub **Actions secrets**.
* `.gitignore` blocks `.env`, `*.pem`, `*.key`. Before every push: `git status` and `git diff --cached`.
* Leaked a secret? **Rotate it at the provider first**, then clean history.

### 4.5 CI workflows in this repo
| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `.github/workflows/ci-lint.yml` | every push / PR | `shellcheck` + `bash -n` on every `scripts/*.sh` |
| `.github/workflows/project-09-build.yml` | push to `project-09-*/**` | compiles the Rust binary + Astro site off-box (Rust builds need >1 GB RAM) and uploads an artifact |
| `.github/workflows/project-10-deploy.yml` | push to `project-10-*/**` | builds, ships over SSH, runs blue/green `zero_downtime_deploy.sh` |

---

## 5. Free-tier accounts you will create

| Service | Used in | Sign-up notes |
|---------|---------|---------------|
| Turso | P02 | `turso db create bookmarks`, `turso db tokens create bookmarks` |
| MongoDB Atlas M0 | P03 | Network Access → add `<EC2_IP>/32` |
| Neon | P04, P10 | copy the connection string (`sslmode=require`) |
| Supabase | P05 | use the **pooler** connection string (port 6543) |
| Aiven (Free MySQL) | P06 | download the **CA certificate** from the service page |
| Upstash Redis | P07, P10 | use the `rediss://` (TLS) URL |
| CockroachDB Cloud (free tier) | P08 | download the CA cert or use `sslmode=verify-full` |
| Cloudflare D1 + R2 | P09 | API token with D1 Edit; R2 S3 API token |
| DuckDNS | P06 | free `<name>.duckdns.org` + token |

Free-tier limits and terms change — re-check each provider's pricing page before relying on it.

---

## 6. Daily hygiene on the 1 GB box
```bash
free -h; swapon --show; df -h /; systemctl --failed; sudo journalctl -p err -b --no-pager | tail -20
```

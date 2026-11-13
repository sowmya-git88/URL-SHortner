# Project 10 — Status Dashboard · GUIDEBOOK

**Stack:** React 18 (bundled by `bun build`) · Bun · Neon Postgres + Upstash Redis · Caddy (blue/green upstreams)
**Linux focus:** CI/CD with GitHub Actions over SSH, deploy users & SSH key restrictions, **least-privilege `sudoers`** (`visudo`), systemd **template units** (`@.service`), blue/green zero-downtime deploys, atomic symlinks, rollback
**Script:** `scripts/zero_downtime_deploy.sh` (+ `.github/workflows/project-10-deploy.yml`)
**RAM budget:** one Bun instance ≈ 50–70 MB; two during cut-over (~30 s)

---

## Part A — Concepts to Learn First

### A1. The CI/CD pipeline
```
git push ─▶ GitHub Actions runner (Ubuntu VM, discarded after the job)
             build: bun install · bun build (React) · bun install --production · tar
             deploy: scp tarball ─▶ EC2 (user deploy) ─▶ ssh "sudo zero_downtime_deploy.sh deploy …"
             smoke test: curl https://<IP>.sslip.io/api/health must report the new version
             on failure: ssh "sudo … rollback"
```
**Build off-box** = no compilers, no `node_modules` downloads and no RAM spikes on the 1 GB server. The server only unpacks and restarts.

### A2. A dedicated deploy identity
* Linux user **`deploy`**: no password, SSH key only, not in the `sudo` group.
* The **private** key lives in GitHub **Secrets** (`EC2_SSH_KEY`), the public key in `/home/deploy/.ssh/authorized_keys` with options: `restrict` disables port/agent/X11 forwarding and PTY allocation — the key can run commands and `scp`, nothing interactive.
* **Host key pinning:** `EC2_KNOWN_HOSTS` (from `ssh-keyscan`) + `StrictHostKeyChecking yes` → the runner refuses to talk to an impostor (MITM).
* **Network:** GitHub-hosted runners use many changing IPs, so port 22 must accept them. Options: (a) open 22 to `0.0.0.0/0` but keep key-only auth + `AllowUsers ubuntu deploy` + Fail2Ban's sshd jail (Project 09), (b) a self-hosted runner, or (c) AWS SSM. This lab uses (a).

### A3. sudo & sudoers, properly
* `/etc/sudoers` + `/etc/sudoers.d/*` (files in `sudoers.d` must be mode `0440`, no `.` or `~` in the name).
* **Always edit with `visudo`** (`visudo -f file` / validate with `visudo -cf file`): a syntax error in sudoers can lock **everyone** out of sudo.
* Rule format: `who  where=(as_whom)  [NOPASSWD:] commands`.
* `Cmnd_Alias` groups commands. **Arguments matter:** `script deploy *` allows any arguments after `deploy`; `script status` (no wildcard) allows exactly that. Wildcards are dangerous → the script re-validates arguments with strict regexes.
* **The script must be root-owned and not writable by `deploy`** (`root:root 0755` in a root-owned directory). Otherwise `deploy` edits the script and becomes root.
* Never allow editors (`vim` → `:!sh`), pagers (`less` → `!sh`), `systemctl edit`, `tar`, `find`, `cp` as root — all are shell escapes / privilege escalation vectors.
* `sudo -l -U deploy` lists what a user may run. Audit trail: `journalctl _COMM=sudo`.

### A4. systemd template units
`statusdash@.service` is a **template**; `statusdash@blue.service` and `statusdash@green.service` are **instances**. `%i` expands to the instance name, so one file gives two services with different env files (`/etc/statusdash/blue.env` → `PORT=5010`, `green.env` → `PORT=5011`) and different working directories (`/opt/statusdash/%i/server`).

### A5. Blue/green deployment
Two identical slots. One serves traffic (**active**), the other is idle.
1. Unpack new release → point the **idle** slot's symlink at it → start idle.
2. **Health gate:** `/api/health` must return 200 *and* the new version string.
3. Mark idle as active, **gracefully stop** the old slot (SIGTERM → Bun `server.stop(false)` finishes in-flight requests).
4. Caddy lists both upstreams with `lb_policy first`, active **health checks** every 2 s and `lb_try_duration 10s` → requests are retried on the healthy slot, users never see an error.
5. **Rollback** = the old slot still points to the previous release → start it, health-check, stop the current one. Seconds, no rebuild.

### A6. Database migrations in zero-downtime land
During cut-over **both versions run against the same database**. Migrations must be **backward compatible** ("expand → migrate → contract"): add a nullable column in release N, start using it in N+1, drop the old one in N+2. Never rename/drop something the old version still reads. Code rollbacks are instant; schema rollbacks are not.

### A7. Atomic symlink switch
`ln -sfn target link` *unlinks then creates* (a tiny window with no link). Atomic version: `ln -sfn target .link.tmp && mv -Tf .link.tmp link` — `rename(2)` replaces the link in one step.

### A8. Background jobs in a multi-instance world
Both slots run the uptime checker. A Redis lock (`SET key value NX PX <ms>`) ensures only one performs each cycle: the first to `SET … NX` wins; the key expires before the next cycle.

### A9. Bash concepts in `zero_downtime_deploy.sh`
Associative arrays (`declare -A PORT=([blue]=5010 …)`), `flock` deploy lock, regex validation of sudo-supplied args, `tar -tz | grep` path-traversal check, `tar --no-same-owner`, `systemd-run --uid … --wait --pipe` (migrations as the app user), health loop with a deadline, `readlink -f`, `mv -Tf` atomic swap, structured logging to journald with `logger`.

---

## Part B — Architecture & Request Flow

```
 GitHub (push to main)
   └─ Actions runner: build → statusdash-<sha>.tgz ──scp──▶ /home/deploy/incoming/
                                                   ──ssh──▶ sudo zero_downtime_deploy.sh deploy … (sudoers: only this)

 Browser ──HTTPS──▶ ┌──────────────────────────── Caddy :443 ────────────────────────────┐
 <IP>.sslip.io      │ reverse_proxy 127.0.0.1:5010 127.0.0.1:5011                        │
                    │   lb_policy first · health_uri /api/health every 2s · lb_try 10s    │
                    └───────────────┬──────────────────────────────┬─────────────────────┘
                                    ▼                              ▼
                 statusdash@blue (:5010)                statusdash@green (:5011)
                 WorkingDirectory=/opt/statusdash/blue  /opt/statusdash/green
                      │ symlink                               │ symlink
                      ▼                                       ▼
          releases/20250131T1010Z-a1b2c3d       releases/20250131T1145Z-e4f5a6b   ← new
                      └──────────────┬────────────────────────┘
                                     ▼
              Neon Postgres (monitors, checks)  ·  Upstash Redis (latest status, checker lock)
```

---

## Part C — Step-by-Step Manual Deployment Lab

### C1. Prerequisites on EC2
```bash
sudo systemctl disable --now mdblog 2>/dev/null || true
cd /tmp && curl -fsSLO https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip
unzip -o bun-linux-x64.zip && sudo install -m 0755 bun-linux-x64/bun /usr/local/bin/bun && bun --version
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --user-group statusdash
sudo install -d -m 0755 -o root -g root /opt/statusdash /opt/statusdash/bin /opt/statusdash/releases /opt/statusdash/state
sudo install -d -m 0750 -o root -g statusdash /etc/statusdash
cd ~/linux-devops-13-projects/project-10-status-dashboard
sudo cp .env.example /etc/statusdash/statusdash.env && sudo nano /etc/statusdash/statusdash.env
sudo cp deploy/blue.env deploy/green.env /etc/statusdash/
sudo chown root:statusdash /etc/statusdash/*.env && sudo chmod 640 /etc/statusdash/*.env
sudo install -m 0755 -o root -g root scripts/zero_downtime_deploy.sh /opt/statusdash/bin/
sudo cp deploy/statusdash@.service /etc/systemd/system/ && sudo systemctl daemon-reload
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

### C2. The deploy user, SSH key and sudo rule
```bash
sudo useradd --create-home --shell /bin/bash deploy
sudo install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh /home/deploy/incoming
# create the CI key pair (on EC2 for convenience; the PRIVATE key goes to GitHub, then delete it here)
ssh-keygen -t ed25519 -N "" -C "github-actions-deploy" -f /tmp/gha_deploy
echo "restrict $(cat /tmp/gha_deploy.pub)" | sudo tee /home/deploy/.ssh/authorized_keys >/dev/null
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys && sudo chmod 600 /home/deploy/.ssh/authorized_keys
# allow the user through the Project 01 SSH hardening
sudo sed -i 's/^AllowUsers .*/AllowUsers ubuntu deploy/' /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t && sudo systemctl reload ssh
# least-privilege sudo
sudo visudo -cf deploy/sudoers/statusdash-deploy
sudo install -m 0440 -o root -g root deploy/sudoers/statusdash-deploy /etc/sudoers.d/statusdash-deploy
sudo visudo -c
sudo -l -U deploy
sudo -u deploy sudo -n /usr/bin/id || echo "denied — correct"
sudo -u deploy sudo -n /opt/statusdash/bin/zero_downtime_deploy.sh status
```

### C3. GitHub secrets
Repository → Settings → Secrets and variables → Actions:
* `EC2_HOST` = public IP · `EC2_SSH_KEY` = contents of `/tmp/gha_deploy` · `EC2_KNOWN_HOSTS` = `ssh-keyscan -t ed25519 <EC2_IP>` (run from your laptop)
* Settings → Environments → create `production` (optionally require manual approval).
Then on EC2: `shred -u /tmp/gha_deploy /tmp/gha_deploy.pub`. In the AWS Security Group, allow 22 from `0.0.0.0/0` (see A2) — Fail2Ban sshd jail stays on.

### C4. First deploy — by hand (same steps CI does)
```bash
cd ~/linux-devops-13-projects/project-10-status-dashboard
(cd web && bun install && bun run build) && (cd server && bun install --production)
rm -rf /tmp/pkg && mkdir -p /tmp/pkg/web && cp -r server /tmp/pkg/ && cp -r web/dist /tmp/pkg/web/
echo manual1 > /tmp/pkg/VERSION && tar -C /tmp/pkg -czf /tmp/statusdash-manual1.tgz .
sudo install -m 0644 -o deploy -g deploy /tmp/statusdash-manual1.tgz /home/deploy/incoming/
sudo -u deploy sudo /opt/statusdash/bin/zero_downtime_deploy.sh deploy /home/deploy/incoming/statusdash-manual1.tgz manual1
sudo /opt/statusdash/bin/zero_downtime_deploy.sh status
ls -l /opt/statusdash/
curl -s https://$(curl -s https://checkip.amazonaws.com).sslip.io/api/health | jq '{color,version}'
```

### C5. Prove zero downtime
Terminal 1 (laptop):
```bash
while true; do curl -s -o /dev/null -w '%{http_code} ' https://<IP>.sslip.io/api/status; sleep 0.2; done
```
Terminal 2: build `manual2` like C4 and deploy it. Terminal 1 must show only `200`s while the colour flips (`curl …/api/health | jq .color`).

### C6. Rollback
```bash
sudo -u deploy sudo /opt/statusdash/bin/zero_downtime_deploy.sh rollback
sudo /opt/statusdash/bin/zero_downtime_deploy.sh status
journalctl -t zero_downtime_deploy -n 20 --no-pager
```

### C7. CI/CD
Commit any change under `project-10-status-dashboard/` and push to `main`. Watch *Actions → project-10-deploy*; the smoke test checks the public URL reports the commit SHA.

---

## Part D — Break-Fix Drills

### Drill 1 — Broken release never reaches users
**Break:** add `throw new Error("boom");` at the top of `server/server.ts`, deploy `bad1`.
**Symptom:** script logs `new release unhealthy — aborting; blue keeps serving`, exit 1; CI job fails and runs rollback (no-op).
**Diagnose:** `journalctl -u statusdash@green -n 30` → the stack trace; `zero_downtime_deploy.sh status` → active unchanged.
**Fix:** revert the commit, push. **Lesson:** health-gated cut-over = bad builds die in the idle slot.

### Drill 2 — `sudo: a password is required` in CI
**Break:** change the sudoers rule to `/opt/statusdash/bin/zero_downtime_deploy.sh deploy` (no `*`) and install it with `visudo -cf` + `install`.
**Symptom:** CI step fails: `sudo: a terminal is required…` / `a password is required`.
**Diagnose:** `sudo -l -U deploy` shows the exact allowed command line; arguments must match the rule.
**Fix:** restore `deploy *`. **Bonus break:** `sudo chmod 777 /opt/statusdash/bin/zero_downtime_deploy.sh` → now `deploy` could edit a script it runs as root = root shell. Detect with `find /opt/statusdash/bin -perm -o+w`; fix `chmod 755`, `chown root:root`.

### Drill 3 — 502s during deploy
**Break:** in the Caddyfile remove `lb_try_duration` and the `health_*` lines, reload Caddy, re-run C5 while deploying.
**Symptom:** a burst of `502` while the old slot stops.
**Diagnose:** `sudo jq -r 'select(.status>=500) | .ts' /var/log/caddy/statusdash.access.log | tail`; Caddy keeps sending requests to the stopped upstream until passive failure marks it down.
**Fix:** restore active health checks + retries. **Lesson:** zero downtime is a property of the *whole* chain (proxy + app shutdown + health checks), not just the script.

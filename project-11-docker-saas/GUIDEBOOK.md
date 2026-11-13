# Project 11 — Docker SaaS (Laptop) · GUIDEBOOK

**Stack:** Next.js 14 (standalone) · NestJS 10 · Postgres 16 · Redis 7 · MinIO · Caddy — all containers
**Linux focus:** what a container really is (namespaces + cgroups + layered filesystem), multi-stage Dockerfiles, image layers & cache, Compose networks (incl. `internal: true`), named volumes, healthchecks + `depends_on: condition`, PID 1 & signals, resource limits, log rotation
**Script:** `scripts/docker_health.sh`
**Runs on:** your Linux laptop (≥ 8 GB RAM recommended)

---

## Part A — Concepts to Learn First

### A1. A container is just a Linux process with a different view
No VM, no second kernel. `dockerd` → `containerd` → `runc` starts a normal process but wraps it in:
* **Namespaces** (what it can *see*): `pid` (its own PID 1), `net` (own interfaces/IP/ports), `mnt` (own root filesystem), `uts` (hostname), `ipc`, `user`. Check: `sudo ls -l /proc/$(docker inspect -f '{{.State.Pid}}' saas-api-1)/ns`.
* **cgroups v2** (what it can *use*): `memory.max`, `cpu.max`, `pids.max` — the same mechanism as systemd's `MemoryMax=` in Project 05. `deploy.resources.limits.memory: 256M` writes `memory.max`.
* **Capabilities & seccomp**: root inside a container has a reduced set of privileges. We still run as **non-root** (`USER node` / `USER nextjs`).
* **Union filesystem (overlay2)**: image layers are read-only and stacked; the container adds one thin writable layer that is **lost** when the container is removed → anything you want to keep goes in a **volume**.

### A2. Images, layers and the build cache
Every Dockerfile instruction creates a layer identified by a hash of its inputs. If inputs don't change, the layer is reused. Order matters:
```dockerfile
COPY package*.json ./      # changes rarely  → npm install layer cached
RUN npm install
COPY src ./src             # changes often   → only these layers rebuild
```
`RUN --mount=type=cache,target=/root/.npm` keeps npm's download cache *between* builds without baking it into the image.

### A3. Multi-stage builds
Build tools (TypeScript, Next's compiler, dev dependencies) are needed to *build*, not to *run*. Each `FROM … AS name` starts a fresh stage; `COPY --from=build` copies only the artefacts. Result for the API: `deps` (all deps) → `build` (tsc) → `prod-deps` (`--omit=dev`) → `runtime` (node_modules + dist). For Next.js, `output: "standalone"` traces exactly which files `server.js` needs. Compare: `docker images | grep saas` and `docker history saas/web:1.0.0`.

### A4. PID 1 and signals inside containers
`docker stop` sends **SIGTERM** to the container's PID 1, waits 10 s, then **SIGKILL** (exit 137 again!). With the **exec form** `CMD ["node", "dist/main.js"]`, Node *is* PID 1 and receives the signal; NestJS `enableShutdownHooks()` closes Postgres/Redis cleanly. The **shell form** `CMD node dist/main.js` runs `/bin/sh -c` as PID 1, which does **not** forward SIGTERM → every stop takes 10 s and ends in SIGKILL.

### A5. Compose networking
* Every network gets its own Linux **bridge** + subnet; containers get a `veth` pair into it.
* Docker's embedded DNS (`127.0.0.11`) resolves **service names**: `api` connects to `postgres:5432`.
* **`internal: true`** → no NAT/gateway to the outside world. Our `data` network holds Postgres/Redis/MinIO: the databases cannot reach the internet and are reachable only from containers attached to `data` (the API).
* `ports: "80:80"` publishes via iptables/nftables DNAT on the **host**. Only Caddy publishes ports (+ MinIO console on `127.0.0.1` only). **Gotcha:** Docker inserts its own firewall rules; `ufw` does *not* filter published container ports. Bind to `127.0.0.1:` when something must stay local.

### A6. Volumes vs bind mounts
| | Named volume (`pgdata:`) | Bind mount (`./Caddyfile:`) |
|--|--|--|
| Lives in | `/var/lib/docker/volumes/<name>/_data` | anywhere on the host |
| Managed by | Docker (`docker volume ls/inspect/rm`) | you |
| Use for | databases, persistent state | config files, source code in dev |
`/docker-entrypoint-initdb.d` scripts run **only when the volume is empty** — change `001_schema.sql` later and nothing happens until `docker compose down -v` (which **deletes data**).

### A7. Healthchecks & startup order
`depends_on: { postgres: { condition: service_healthy } }` waits until Postgres's **healthcheck** passes, not just until the process starts. Health states: `starting` → `healthy` / `unhealthy`. Docker does not restart unhealthy containers by itself (Swarm/K8s do) — `docker_health.sh --restart-unhealthy` can.

### A8. Restart policies & logging
`restart: unless-stopped` → restart on crash and after reboot, unless you stopped it. The `json-file` driver writes `/var/lib/docker/containers/<id>/<id>-json.log`; **without `max-size` it grows forever** (classic full-disk incident) — we cap at 3 × 10 MB per container.

### A9. TLS on a laptop
Let's Encrypt can't reach your laptop, so Caddy's `local_certs` issues certificates from its own **local CA**. `https://127.0.0.1.sslip.io` works (browser warning until you trust the root: `docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt .` and import it). Plain `http://127.0.0.1` also works.

### A10. Bash concepts in `docker_health.sh`
`docker inspect --format` Go templates (`{{.State.Health.Status}}`, `{{index .Config.Labels "…"}}`, `{{range}}`), label filters (`--filter label=com.docker.compose.project=saas`), associative array built from one `docker stats --no-stream` call, `IFS='|' read -r a b c < <(…)`, here-strings `<<<`, `[[ -t 1 ]]` colour detection, `--watch` loop with `clear`.

---

## Part B — Architecture & Request Flow

```
 Browser
 https://127.0.0.1.sslip.io  (Caddy local CA)   /   http://127.0.0.1
     │  host ports 80/443 (DNAT by Docker)
     ▼
 ┌───────────────────────────── network: edge (bridge) ─────────────────────────────┐
 │  caddy:2.8 ──/api/*──▶ api:3000 (NestJS, USER node)                              │
 │     └──────── /* ────▶ web:3000 (Next.js standalone, USER nextjs)                │
 └──────────────────────────────────────┬───────────────────────────────────────────┘
                                        │ api is attached to BOTH networks
 ┌──────────────────── network: data (bridge, internal: true — no internet) ────────┐
 │  postgres:5432  ◀─ pg Pool          redis:6379 ◀─ cache + rate limit             │
 │  vol: pgdata    initdb: ./db/init   vol: redisdata (AOF)                         │
 │  minio:9000 ◀─ S3 API (files)       console 127.0.0.1:9001 (host loopback only)  │
 │  vol: miniodata                                                                   │
 └───────────────────────────────────────────────────────────────────────────────────┘
 Startup order: postgres/redis/minio healthy → api healthy → web healthy → caddy
```

---

## Part C — Step-by-Step Lab (laptop)

### C1. Install Docker Engine + Compose plugin
```bash
# Ubuntu/Debian laptop
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && less /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh
sudo usermod -aG docker "$USER" && newgrp docker    # docker group = root-equivalent; understand that!
docker version && docker compose version
```

### C2. Configure & build
```bash
cd ~/linux-devops-13-projects/project-11-docker-saas
cp .env.example .env && nano .env          # set real passwords
docker compose config | less               # fully rendered config (env substituted)
DOCKER_BUILDKIT=1 docker compose build
docker images | grep saas                  # compare sizes
docker history saas/api:1.0.0 | head -12
```

### C3. Start and watch the dependency order
```bash
docker compose up -d
docker compose ps                           # health column: starting → healthy
docker compose logs -f --tail 20 api        # Ctrl+C
scripts/docker_health.sh
```
Open `http://127.0.0.1` and `https://127.0.0.1.sslip.io`. Upload a file, add tasks (note "served from redis/postgres").

### C4. Inspect the isolation
```bash
docker network ls | grep saas
docker network inspect saas_data --format '{{.Internal}} {{range .Containers}}{{.Name}} {{end}}'
docker compose exec api nslookup postgres 127.0.0.11       # resolves: api is on the data network
docker compose exec web nslookup postgres 127.0.0.11 || echo "web cannot even resolve postgres ✓"
docker compose exec postgres sh -c 'wget -qO- -T 3 https://example.com || echo "no internet from data network ✓"'
PID=$(docker inspect -f '{{.State.Pid}}' saas-api-1); sudo ls -l /proc/$PID/ns
cat /sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' saas-api-1).scope/memory.max
docker compose exec api id                   # uid=1000(node)
```

### C5. Volumes & persistence
```bash
docker volume ls | grep saas
sudo ls /var/lib/docker/volumes/saas_pgdata/_data | head
docker compose down && docker compose up -d   # data survives (volumes kept)
# docker compose down -v  ← would DELETE all volumes (and re-run initdb on next up)
docker compose exec postgres pg_dump -U saas saas > backup.sql && ls -lh backup.sql
```

### C6. Signals & PID 1
```bash
time docker compose stop api        # ~1 s: node is PID 1 and handles SIGTERM
docker compose start api
docker compose exec api cat /proc/1/cmdline | tr '\0' ' '; echo
```

---

## Part D — Break-Fix Drills

### Drill 1 — API stuck in "unhealthy", Caddy never starts
**Break:** in `.env` change `POSTGRES_PASSWORD` *after* the first `up` (the volume already holds the old password), then `docker compose up -d --force-recreate api`.
**Symptom:** `api` unhealthy; `caddy` waits (`depends_on: service_healthy`).
**Diagnose:**
```bash
scripts/docker_health.sh            # health probe output + last logs: "password authentication failed"
docker compose exec postgres psql -U saas -c 'select 1'
```
**Fix:** restore the old password (or `ALTER USER saas PASSWORD '…'` inside Postgres). **Lesson:** `POSTGRES_PASSWORD` is only applied when initialising an **empty** volume.

### Drill 2 — OOMKilled (exit 137) in a container
**Break:** set the api `memory` limit to `40M`, `docker compose up -d api`.
**Symptom:** restart loop; `docker_health.sh` shows `OOM YES`, `EXIT 137`, RST climbing.
**Diagnose:** `docker inspect -f '{{.State.OOMKilled}} {{.State.ExitCode}}' saas-api-1`; `docker stats`; `journalctl -k -g oom | tail -3`.
**Fix:** restore `256M`. Same kernel mechanism as Project 05 — just a different cgroup.

### Drill 3 — "My schema change didn't apply" / disk full of logs
**Break A:** add a column to `db/init/001_schema.sql`, `docker compose up -d`.
**Symptom A:** column missing.
**Diagnose A:** `docker compose logs postgres | grep -i 'skipping initialization'` → the data directory already exists.
**Fix A:** write a real migration (`docker compose exec -T postgres psql -U saas saas < migration.sql`) or, in dev only, `docker compose down -v`.
**Break B:** remove the `logging:` anchor and run `while true; do curl -s localhost/api/tasks >/dev/null; done` for a while.
**Diagnose B:** `sudo du -sh /var/lib/docker/containers/*/*-json.log | sort -h | tail -3`; `docker system df`.
**Fix B:** restore `max-size`/`max-file`, recreate containers (`docker compose up -d --force-recreate`). **Lesson:** container logs need rotation just like Project 08's PM2 logs.

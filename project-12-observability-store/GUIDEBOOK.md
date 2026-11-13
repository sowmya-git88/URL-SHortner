# Project 12 — Observability Store (Laptop) · GUIDEBOOK

**Stack:** React (Vite → Nginx) · Spring Boot 3.3 / Java 21 · Kafka 3.8 (KRaft) · Postgres 16 · **Prometheus + Grafana + Node Exporter**
**Linux focus:** metrics vs logs vs traces, the pull model, `/proc`-based host metrics, PromQL (`rate`, `histogram_quantile`, aggregation), alert rules & their lifecycle, Grafana provisioning-as-code, JVM memory in containers, event-driven flow with Kafka
**Script:** `scripts/alert_test.sh`
**Runs on:** your laptop (≈ 3 GB RAM for the whole stack)

---

## Part A — Concepts to Learn First

### A1. Three pillars of observability
* **Logs** — discrete events with detail ("order 42 fulfilled"). Great for *why*. (Projects 03, 07.)
* **Metrics** — numbers over time, cheap to store and query ("5xx per second"). Great for *is something wrong, how much, since when*. **This project.**
* **Traces** — the path of one request across services. (Next step: OpenTelemetry.)

### A2. How Prometheus works
* **Pull model:** every `scrape_interval` Prometheus does `GET http://target/metrics` and stores each sample in its local **TSDB** (`/prometheus` volume). If a scrape fails, the synthetic metric `up{job=…}` becomes `0` — the basis of `StoreAppDown`.
* **Exposition format:** plain text, e.g. `http_server_requests_seconds_count{method="GET",status="200",uri="/api/products"} 1234`. A metric name + **labels** = one **time series**. Beware high-cardinality labels (user IDs!) — each unique combination is a new series.
* **Metric types:** *counter* (only goes up; `_total`), *gauge* (up and down: `orders_pending`, memory), *histogram* (`_bucket{le=…}`, `_sum`, `_count` → percentiles).

### A3. Where the numbers come from
* **Node Exporter** reads the kernel's own counters from `/proc` and `/sys` — the same files `top`, `free`, `df` and `iostat` read: `/proc/stat` → `node_cpu_seconds_total`, `/proc/meminfo` → `node_memory_MemAvailable_bytes`, `statfs()` → `node_filesystem_avail_bytes`. That's why the container mounts the host root at `/host` (read-only) and uses `pid: host`.
* **Spring Boot Actuator + Micrometer** expose JVM, HTTP, Hikari pool and our **business metrics** (`orders_created_total`, `orders_fulfilled_total`, `orders_pending`, `orders_fulfillment_latency_seconds`) at `/actuator/prometheus`.

### A4. PromQL in 6 patterns
| Question | PromQL |
|----------|--------|
| Is it up? | `up{job="store-app"}` |
| Requests per second (from a counter) | `sum(rate(http_server_requests_seconds_count[1m]))` |
| Error ratio | `sum(rate(…{status=~"5.."}[1m])) / sum(rate(…[1m]))` |
| p95 latency | `histogram_quantile(0.95, sum by (le) (rate(…_bucket[2m])))` |
| CPU busy % | `100 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100` |
| Per-label breakdown | `sum by (status) (rate(…[1m]))` |
`rate()` turns an ever-increasing counter into a per-second speed and handles counter resets on restart. Always `rate` *then* `sum`.

### A5. Alert lifecycle
Rules are evaluated every `evaluation_interval` (15 s): expression true → **pending**; still true after `for:` → **firing**; false → **inactive** (resolved). So "app stopped" → firing takes ≈ scrape (10 s) + `for` (30 s) + evaluation (≤ 15 s) ≈ **1 minute**. `for:` prevents paging on a single blip. (Routing alerts to email/Slack is Alertmanager's job — the natural next step.)

### A6. Grafana provisioning-as-code
Instead of clicking, files under `/etc/grafana/provisioning` declare the **datasource** (Prometheus URL) and a **dashboard provider** that loads JSON dashboards from `/var/lib/grafana/dashboards`. Rebuild the laptop → identical dashboards. `disableDeletion` / `allowUiUpdates: false` keep Git the source of truth.

### A7. Kafka in one paragraph
A distributed, append-only **log**. Producers append messages to a **topic** split into **partitions**; consumers in a **group** split the partitions and track their **offset**. Here: `POST /api/orders` → row in Postgres → message `orderId` to topic `orders` (sent **after commit**) → the `fulfillment` consumer marks it fulfilled. Delivery is **at-least-once** → the consumer is **idempotent** (`WHERE status = 'CREATED'`). If the consumer stops, messages wait — `orders_pending` grows → `OrdersNotFulfilled` fires. **KRaft mode** = Kafka manages its own metadata quorum (no ZooKeeper).

### A8. The JVM in a container
Modern JVMs are **container-aware**: they read the cgroup limit (`768M`). `-XX:MaxRAMPercentage=70` → heap ≈ 537 MB, leaving room for metaspace, threads, and buffers (non-heap). `-XX:+ExitOnOutOfMemoryError` → exit (and let Docker restart) instead of limping on. Layered jars (`layertools extract`) put rarely-changing dependencies in their own image layer → faster rebuilds.

### A9. Bash concepts in `alert_test.sh`
Querying JSON APIs with `curl | jq --arg`, polling with deadlines, background load generators stored in an array of PIDs (`$!`), `trap cleanup EXIT INT TERM` that **always** restarts the app and kills load, `nproc`, associative-array result table, `docker compose exec -T` (no TTY, for scripts).

---

## Part B — Architecture & Request Flow

```
 Browser ─▶ http://127.0.0.1:8080
             │
 ┌───────────▼───────────── network: app ─────────────────────────────────────────────┐
 │ web (Nginx: React build, /api → store-app:8080)                                     │
 │    │                                                                                │
 │    ▼                                                                                │
 │ store-app (Spring Boot, Java 21, 768M limit) ── JDBC ──▶ postgres (orders, products)│
 │    │  POST /api/orders → INSERT → after commit → produce "orders" ─▶ kafka (KRaft)  │
 │    │  @KafkaListener(fulfillment) ◀─────────────── consume ◀────────┘               │
 └────┼────────────────────────────────────────────────────────────────────────────────┘
      │ /actuator/prometheus (every 10 s)
 ┌────▼──────────────── network: monitoring ─────────────────────────────────────────┐
 │ prometheus :9090 (127.0.0.1 only) ── scrapes ──▶ store-app, node-exporter, itself │
 │    │  alert.rules.yml: StoreAppDown, HighHttpErrorRate, SlowRequestsP95,          │
 │    │                   OrdersNotFulfilled, JvmHeapHigh, HostHighCpu, HostLowMemory│
 │    ▼                                                                               │
 │ grafana :3000 (127.0.0.1 only) ── provisioned datasource + "Store · Overview"     │
 │ node-exporter (pid: host, / mounted ro at /host) ── reads host /proc, /sys        │
 └────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Part C — Step-by-Step Lab (laptop)

### C1. Start the stack
```bash
cd ~/linux-devops-13-projects/project-12-observability-store
cp .env.example .env && nano .env
docker compose build              # first Maven build downloads dependencies (several minutes)
docker compose up -d
docker compose ps                 # wait until store-app is healthy (~60 s: JVM + Flyway + Kafka)
curl -s http://127.0.0.1:8080/api/health | jq
```
Shop: `http://127.0.0.1:8080` · Prometheus: `http://127.0.0.1:9090` · Grafana: `http://127.0.0.1:3000` (folder *DevOps Lab*).

### C2. Look at raw metrics before any dashboard
```bash
docker compose exec store-app wget -qO- http://127.0.0.1:8080/actuator/prometheus | grep -E '^orders_|^http_server_requests_seconds_count' | head
docker compose exec prometheus wget -qO- http://node-exporter:9100/metrics | grep -E '^node_memory_MemAvailable|^node_load1'
grep MemAvailable /proc/meminfo; cat /proc/loadavg        # same numbers, straight from the kernel
```

### C3. PromQL by hand (Prometheus UI → Graph)
Click *Load test* in the shop a few times, then run each query from A4. Also: `orders_pending`, `sum(rate(orders_created_total[1m])) * 60`, `count(ALERTS{alertstate="firing"})`.

### C4. Validate & list rules
```bash
scripts/alert_test.sh check
scripts/alert_test.sh list
```

### C5. Fire alerts on purpose
```bash
scripts/alert_test.sh down       # ~1–2 min to fire, then resolves after restart
scripts/alert_test.sh errors
scripts/alert_test.sh cpu        # your fans will spin up for ~2 min
scripts/alert_test.sh all        # full run + PASS/FAIL table
```
Keep the Grafana dashboard open: watch *Firing alerts*, *5xx ratio* and *Host CPU* change.

### C6. Business alert via Kafka
```bash
docker compose stop kafka
# within ~60 s place ~25 orders (Load test button) → requests succeed, the producer buffers, fulfillment stops
docker compose start kafka         # restart before the producer's delivery.timeout.ms (120 s) expires
```
If Kafka stays down longer than the producer timeout, those events are **lost** and the orders stay `CREATED` forever — exactly the problem the *transactional outbox* pattern solves (write the event to a DB table in the same transaction, publish it from there).
Watch `orders_pending` and the `OrdersNotFulfilled` alert, then everything drain once Kafka is back.

---

## Part D — Break-Fix Drills

### Drill 1 — Target DOWN: "context deadline exceeded" / 404 on `/actuator/prometheus`
**Break:** in `application.yml` remove `prometheus` from `management.endpoints.web.exposure.include`, `docker compose up -d --build store-app`.
**Symptom:** Prometheus → Status → Targets: `store-app` DOWN, `server returned HTTP status 404`; `StoreAppDown` fires though the shop works.
**Diagnose:** `curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health, lastError}'`.
**Fix:** re-expose the endpoint, rebuild. **Lesson:** `up == 0` means "can't scrape", not necessarily "app is dead" — always read `lastError`.

### Drill 2 — Rule file breaks Prometheus reload
**Break:** introduce a typo in `alert.rules.yml` (e.g. `expr: up{job="store-app" == 0`), then `curl -X POST localhost:9090/-/reload`.
**Symptom:** reload returns an error; Prometheus keeps the **old** rules (or fails to start after a restart).
**Diagnose:** `scripts/alert_test.sh check` → promtool shows file, line and parse error; `docker compose logs prometheus | tail`.
**Fix:** correct the YAML, `check`, reload. **Lesson:** lint rules in CI (`promtool check rules`) exactly like `nginx -t` / `sshd -t`.

### Drill 3 — Java container keeps restarting (exit 137 / OOM)
**Break:** set the store-app memory limit to `256M` and `JAVA_OPTS=-Xmx400m`; `docker compose up -d store-app`; click *Load test* a few times.
**Symptom:** container restarts; `docker inspect -f '{{.State.OOMKilled}}' obs-store-app-1` → `true`; Grafana heap graph saw-tooths then drops to nothing.
**Diagnose:** heap max (400 MB) > cgroup limit (256 MB): the kernel kills the JVM before the GC feels pressure.
**Fix:** never hard-code `-Xmx` above the limit; use `MaxRAMPercentage` and a realistic limit (`768M`). **Lesson:** the same OOM story as Projects 05 and 11, one more runtime.

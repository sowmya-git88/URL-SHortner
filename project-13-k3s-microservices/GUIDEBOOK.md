# Project 13 — k3s Microservices (Laptop) · GUIDEBOOK

**Stack:** React (nginx-unprivileged) · Go API (distroless) · Python worker · Postgres 16 StatefulSet · **k3s** (Traefik Ingress, local-path storage, metrics-server) · **Ansible**
**Linux focus:** what Kubernetes adds on top of containers, the control loop, Pods/Deployments/StatefulSets/Services/Ingress, probes, resource requests & limits (cgroups again), Secrets/ConfigMaps, PersistentVolumes, NetworkPolicy, Pod Security, HPA, and **idempotent provisioning with Ansible**
**Script:** `scripts/cluster_bootstrap.sh` (+ `ansible/playbook.yml`)
**Runs on:** your laptop (≥ 4 GB free RAM, 2+ CPUs)

---

## Part A — Concepts to Learn First

### A1. From Compose to Kubernetes
Compose (Project 11) *starts* containers on one machine. Kubernetes continuously **reconciles**: you declare *desired state* ("2 API pods, ready, ≤128 MiB each"), controllers compare it with *actual state* and act (start, kill, reschedule) forever. That **control loop** is the whole idea.

### A2. k3s anatomy (one binary, one systemd unit)
`/usr/local/bin/k3s` runs as `k3s.service` and contains: **API server** (`:6443`, everything talks to it), **scheduler** (picks a node for each pod), **controller-manager** (the reconcile loops), **kubelet** (starts pods on this node), **containerd** (runtime — *not* Docker!), **flannel** (pod network, VXLAN), **kube-proxy** (Service VIPs via iptables), **CoreDNS**, **Traefik** (Ingress on :80/:443), **local-path-provisioner** (PVCs → host directories), **metrics-server** (CPU/RAM for `kubectl top` and HPA), and an embedded **NetworkPolicy** controller. State lives in SQLite at `/var/lib/rancher/k3s/server/db/`. Kubeconfig: `/etc/rancher/k3s/k3s.yaml`.

Because k3s uses its *own* containerd, images built with Docker must be **imported**: `docker save img | sudo k3s ctr images import -` and pods use `imagePullPolicy: Never`.

### A3. The objects in `k8s/`
| Object | Role here |
|--------|-----------|
| **Namespace** `microsvc` | isolation boundary + Pod Security label `restricted` |
| **ConfigMap** `app-config` | non-secret settings → env vars |
| **Secret** `db-credentials` | password + DSN (base64 ≠ encryption! created by the script, never in Git) |
| **StatefulSet** `postgres` | stable identity `postgres-0`, its **own PVC** that survives pod deletion |
| **Headless Service** `postgres` | DNS → pod IP directly |
| **Deployment** `api` / `worker` / `web` | stateless, replaceable replicas, rolling updates |
| **Service** `api` / `web` | stable virtual IP + DNS name load-balancing across ready pods |
| **Ingress** | Traefik routes `/api` → api:8080, `/` → web:80 |
| **HPA** `api` | 2–5 replicas based on CPU vs. **request** |
| **PodDisruptionBudget** | keeps ≥ 1 API pod during voluntary disruptions (drain) |
| **NetworkPolicy** | default-deny; only api/worker → postgres; only Traefik → api/web |

### A4. Probes — the most misunderstood feature
* **readinessProbe** → "send me traffic?" Failing = pod removed from the Service endpoints (not restarted). Our API checks Postgres here.
* **livenessProbe** → "am I wedged?" Failing = container **restarted**. Must **not** check dependencies — if Postgres is down, restarting every API pod makes it worse (cascading restarts). Our API's `/livez` checks nothing external.
* Worker has no HTTP port → **exec** probe: "heartbeat file touched in the last 30 s".

### A5. Requests, limits and the Linux underneath
* `requests` = what the **scheduler** reserves (and the HPA's 100 %). `limits` = cgroup ceilings: `memory` → `memory.max` → OOMKill (exit **137**, `OOMKilled` in `kubectl describe pod`), `cpu` → CFS throttling (slow, not killed).
* QoS class: Guaranteed / Burstable / BestEffort decides who gets evicted first under node pressure.

### A6. Graceful termination in Kubernetes
On delete/rollout: pod marked *Terminating* → removed from endpoints **asynchronously** → `SIGTERM` → `terminationGracePeriodSeconds` → `SIGKILL`. The Go API fails readiness and keeps serving for 5 s before shutting down so no request hits a closing socket; the worker finishes its current job. `maxUnavailable: 0` + `maxSurge: 1` = zero-downtime rolling updates.

### A7. Work distribution without a broker
`SELECT … FOR UPDATE SKIP LOCKED LIMIT 1` lets N worker replicas pull from one Postgres table without double-processing: a locked row is simply skipped by the others. Jobs stuck in `running` (worker SIGKILLed) are re-queued after 120 s.

### A8. Security baseline
Non-root numeric UIDs, `allowPrivilegeEscalation: false`, `capabilities: drop ALL`, `seccompProfile: RuntimeDefault`, read-only root filesystems (writable `emptyDir` for `/tmp`), distroless API image (no shell to exec into). The namespace label `pod-security.kubernetes.io/enforce: restricted` makes the API server **reject** pods that don't comply.

### A9. Ansible: idempotent configuration management
* **Inventory** (`inventory.ini`) = which hosts; **playbook** = ordered **tasks** using **modules** (`apt`, `copy`, `systemd`, `get_url`, `uri`, `command`).
* **Idempotency:** running it twice changes nothing the second time. Modules are idempotent by design; for `command`/`shell` you add `creates:`, `changed_when:` or `--dry-run=client | kubectl apply` patterns.
* `become: true` → sudo; `tags` run slices (`--tags deploy`); `--check --diff` = dry run; `no_log: true` hides secrets in output; variables in `group_vars/all.yml`, secrets via env or `ansible-vault`.
* The same playbook works against a remote box by changing one inventory line.

### A10. Bash concepts in `cluster_bootstrap.sh`
Command arrays (`KUBECTL=(sudo k3s kubectl)` + `"${KUBECTL[@]}"`), `set -a; . .env; set +a`, `trap '… ${BASH_COMMAND}' ERR` (shows *which* command failed), `ss -Htlnp 'sport = :80'` port ownership checks, the `create --dry-run=client -o yaml | kubectl apply -f -` idempotent-secret idiom, polling with bounded loops, interactive confirmation with `read -r -p` for destructive actions.

---

## Part B — Architecture & Request Flow

```
 Browser ─▶ http://127.0.0.1  (or http://<LAN-IP>.sslip.io)
              │  :80 bound by k3s ServiceLB (svclb pod) → Traefik
 ┌────────────▼──────────────────────────── k3s node (your laptop) ───────────────────────────────────┐
 │ kube-system: Traefik Ingress Controller ── Ingress "microsvc" ──┬── /api ─▶ Service api:8080        │
 │                                                                 └── /    ─▶ Service web:80          │
 │ namespace microsvc (PSA: restricted, NetworkPolicy: default deny)                                  │
 │                                                                                                    │
 │  Deployment web (2)        Deployment api (2–5, HPA)          Deployment worker (N)                │
 │  nginx-unprivileged :8080  Go distroless :8080                Python, exec liveness (heartbeat)    │
 │  /healthz                  readiness /api/health (DB)         SELECT … FOR UPDATE SKIP LOCKED      │
 │                            liveness  /livez (no deps)              │                               │
 │                                   │ INSERT jobs                    │ UPDATE jobs                   │
 │                                   ▼                                ▼                               │
 │                     Headless Service postgres ─▶ StatefulSet postgres-0 (uid 70)                   │
 │                                                    PVC data-postgres-0 (local-path, 1Gi)           │
 │                                                    → /var/lib/rancher/k3s/storage/pvc-…            │
 │  Secret db-credentials · ConfigMap app-config · ConfigMap postgres-initdb (001_schema.sql)         │
 └────────────────────────────────────────────────────────────────────────────────────────────────────┘
   Provisioned by: ansible-playbook playbook.yml   or   scripts/cluster_bootstrap.sh all
```

---

## Part C — Step-by-Step Lab (laptop)

### C1. Prerequisites
```bash
# Free ports 80/443 from earlier capstones
(cd ../project-11-docker-saas && docker compose down) 2>/dev/null || true
(cd ../project-12-observability-store && docker compose down) 2>/dev/null || true
docker --version || (sudo apt-get update && sudo apt-get install -y docker.io && sudo usermod -aG docker "$USER")
cd ~/linux-devops-13-projects/project-13-k3s-microservices
cp .env.example .env && nano .env
scripts/cluster_bootstrap.sh preflight
```

### C2. Path A — Bash (understand every step)
```bash
scripts/cluster_bootstrap.sh install
systemctl status k3s --no-pager | head -5
kubectl get nodes -o wide; kubectl get pods -A          # Traefik, CoreDNS, metrics-server, local-path
scripts/cluster_bootstrap.sh build
scripts/cluster_bootstrap.sh deploy
scripts/cluster_bootstrap.sh smoke
scripts/cluster_bootstrap.sh status
```
Open `http://127.0.0.1` → submit jobs → watch which worker pod processes each one.

### C3. Path B — Ansible (same result, declarative + idempotent)
```bash
sudo apt-get install -y ansible            # or: pipx install ansible-core
cd ansible
ansible-playbook playbook.yml --syntax-check
ansible-playbook playbook.yml --check --diff --tags base --ask-become-pass
DB_PASSWORD="$(grep ^DB_PASSWORD ../.env | cut -d= -f2)" ansible-playbook playbook.yml --ask-become-pass
ansible-playbook playbook.yml --tags base,k3s --ask-become-pass   # 2nd run: changed=0 for these tags → idempotent
```

### C4. Explore what Kubernetes is doing
```bash
NS="-n microsvc"
kubectl $NS get all,pvc,ingress,networkpolicy
kubectl $NS describe pod -l app=api | sed -n '/Conditions/,/Events/p'
kubectl $NS get endpoints api -o wide                    # ready pod IPs behind the Service
kubectl $NS logs deploy/worker -f --max-log-requests 5   # (Ctrl+C)
kubectl $NS exec -it postgres-0 -- psql -U app -d microsvc -c "select status, count(*) from jobs group by 1;"
sudo ls /var/lib/rancher/k3s/storage/                    # the PVC as a host directory
kubectl $NS top pods
```

### C5. Self-healing, scaling, rolling updates
```bash
kubectl $NS delete pod -l app=api --wait=false && kubectl $NS get pods -w      # replaced automatically
scripts/cluster_bootstrap.sh scale-worker 5      # click "Submit 25 jobs" → 5 workers share the queue
kubectl $NS rollout restart deployment/api && kubectl $NS rollout status deployment/api
kubectl $NS rollout history deployment/api
# HPA: generate load from inside the cluster
kubectl $NS run load --image=busybox:1.36 --restart=Never -- sh -c 'while true; do wget -qO- http://api:8080/api/jobs >/dev/null; done'
kubectl $NS get hpa api -w        # watch TARGETS rise and REPLICAS grow; then: kubectl $NS delete pod load
```
> The `load` pod is not "restricted"-compliant, so Pod Security **warns/rejects** it — read the message: that's PSA working. To run it, temporarily use a namespace without the label (`kubectl create ns loadtest` and target `http://api.microsvc:8080`) — and note NetworkPolicy then blocks it: perfect bonus drill.

---

## Part D — Break-Fix Drills

### Drill 1 — `ErrImageNeverPull` / `ImagePullBackOff`
**Break:** bump `newTag` for `microsvc/api` to `1.0.1` in `k8s/kustomization.yaml`, `kubectl apply -k k8s` (without building/importing 1.0.1).
**Symptom:** new API pods stuck; old ones keep serving (because `maxUnavailable: 0`).
**Diagnose:** `kubectl -n microsvc describe pod -l app=api | grep -A3 Events`; `sudo k3s crictl images | grep microsvc`.
**Fix:** `IMAGE_TAG=1.0.1 scripts/cluster_bootstrap.sh build` (then the rollout completes) or revert the tag. **Lesson:** k3s' containerd ≠ your Docker image store.

### Drill 2 — Liveness that checks the database → restart storm
**Break:** change the API `livenessProbe` path to `/api/health`, apply, then `kubectl -n microsvc scale statefulset postgres --replicas=0`.
**Symptom:** every API pod restarts repeatedly (`RESTARTS` climbing, `CrashLoopBackOff`), even though nothing is wrong with the API itself.
**Diagnose:** `kubectl -n microsvc get pods -w`, `kubectl describe pod` → `Liveness probe failed: HTTP probe failed with statuscode: 503`.
**Fix:** liveness back to `/livez`; scale Postgres back to 1. With the correct config, API pods just become **NotReady** (out of the Service) and recover by themselves when the DB returns. **Lesson:** readiness = dependencies, liveness = self.

### Drill 3 — Postgres `Pending` / data lost / blocked by policy
**Break A:** `kubectl -n microsvc delete pvc data-postgres-0` while the pod runs, then delete the pod.
**Symptom A:** `postgres-0` Pending or a fresh empty database (all jobs gone, seed rows back).
**Diagnose A:** `kubectl -n microsvc get pvc,pv`, `kubectl describe pod postgres-0` (`persistentvolumeclaim not found` / waiting for first consumer).
**Lesson A:** a PVC *is* the data; StatefulSets keep their PVCs across pod deletion, but deleting the PVC deletes the data (local-path reclaim policy `Delete`). Back up with `kubectl exec postgres-0 -- pg_dump …`.
**Break B:** in `networkpolicy.yaml` remove the `worker` selector from `postgres-from-backend`, apply.
**Symptom B:** jobs stay `queued`; worker logs `database unavailable … timeout`.
**Diagnose B:** `kubectl -n microsvc logs deploy/worker | tail`; `kubectl -n microsvc get networkpolicy postgres-from-backend -o yaml`.
**Fix B:** restore the selector. **Lesson:** default-deny + explicit allows — every new consumer needs a rule.

---

## Where to go next
Push images to a registry (GHCR) instead of importing, add Helm, Argo CD (GitOps), cert-manager for real TLS, Prometheus Operator (connect Project 12's skills), and run the Ansible playbook against a cheap multi-node lab.

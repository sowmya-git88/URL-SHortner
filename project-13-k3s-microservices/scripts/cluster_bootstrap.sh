#!/usr/bin/env bash
# =============================================================================
# cluster_bootstrap.sh — install k3s, build+import images, deploy, verify
# Project 13 · linux-devops-13-projects   (the Bash twin of ansible/playbook.yml)
#
#   scripts/cluster_bootstrap.sh preflight      # RAM/CPU/ports/tools checks
#   scripts/cluster_bootstrap.sh install        # k3s via get.k3s.io (sudo), kubeconfig for you
#   scripts/cluster_bootstrap.sh build          # docker build + import into k3s containerd
#   scripts/cluster_bootstrap.sh deploy         # namespace, secret, kustomize apply, rollout wait
#   scripts/cluster_bootstrap.sh smoke          # end-to-end test through the Ingress
#   scripts/cluster_bootstrap.sh status         # nodes, pods, svc, ingress, hpa, events
#   scripts/cluster_bootstrap.sh scale-worker N # change worker replicas
#   scripts/cluster_bootstrap.sh destroy        # delete the namespace (keeps k3s)
#   scripts/cluster_bootstrap.sh uninstall      # remove k3s completely
#   scripts/cluster_bootstrap.sh all            # preflight → install → build → deploy → smoke
#
# Reads DB_PASSWORD, IMAGE_TAG, NAMESPACE from the environment or ./.env
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "${ROOT}/.env" ]] && set -a && . "${ROOT}/.env" && set +a
NAMESPACE="${NAMESPACE:-microsvc}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
DB_PASSWORD="${DB_PASSWORD:-}"
SERVICES=(api worker web)
KUBECTL=(kubectl)

step() { printf '\n\e[1;34m==> %s\e[0m\n' "$*"; }
ok()   { printf '\e[32m  ✓ %s\e[0m\n' "$*"; }
warn() { printf '\e[33m  ! %s\e[0m\n' "$*"; }
die()  { printf '\e[31m  ✗ %s\e[0m\n' "$*" >&2; exit 1; }
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

pick_kubectl() {
  if command -v kubectl >/dev/null && kubectl version --request-timeout=3s >/dev/null 2>&1; then KUBECTL=(kubectl)
  elif command -v k3s >/dev/null; then KUBECTL=(sudo k3s kubectl)
  else die "no working kubectl — run: $0 install"; fi
}
k() { "${KUBECTL[@]}" "$@"; }

cmd_preflight() {
  step "preflight"
  [[ "$(uname -s)" == Linux ]] || die "Linux required"
  local mem_gb cpus
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
  cpus=$(nproc)
  (( mem_gb >= 4 )) && ok "RAM ${mem_gb} GB" || warn "RAM ${mem_gb} GB — 4 GB+ recommended"
  (( cpus >= 2 )) && ok "${cpus} CPUs" || warn "${cpus} CPU — 2+ recommended"
  local t
  for t in curl docker; do command -v "${t}" >/dev/null && ok "${t} present" || die "${t} missing (see GUIDEBOOK C1)"; done
  docker info >/dev/null 2>&1 && ok "docker daemon reachable" || die "cannot reach docker (group membership? sudo systemctl start docker)"
  local p owner
  for p in 80 443 6443; do
    owner=$(sudo ss -Htlnp "sport = :${p}" 2>/dev/null | grep -oE 'users:\(\("[^"]+' | cut -d'"' -f2 | sort -u | paste -sd, - || true)
    if [[ -z "${owner}" ]]; then ok "port ${p} free"
    elif [[ "${owner}" =~ (k3s|traefik|svclb|containerd) ]]; then ok "port ${p} used by k3s (${owner})"
    else warn "port ${p} used by '${owner}' — stop Project 11/12 (docker compose down) or Traefik can't bind"; fi
  done
  local free_gb; free_gb=$(df -BG --output=avail /var/lib | tail -1 | tr -dc '0-9')
  (( free_gb >= 10 )) && ok "${free_gb} GB free in /var/lib" || warn "only ${free_gb} GB free in /var/lib"
}

cmd_install() {
  step "install k3s"
  if command -v k3s >/dev/null && systemctl is-active --quiet k3s; then
    ok "k3s already running ($(k3s --version | head -1))"
  else
    curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
    sudo INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh /tmp/k3s-install.sh
  fi
  step "wait for node Ready"
  sudo k3s kubectl wait --for=condition=Ready node --all --timeout=180s
  install -d -m 700 "${HOME}/.kube"
  sudo cat /etc/rancher/k3s/k3s.yaml > "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  if ! command -v kubectl >/dev/null; then
    sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
  fi
  ok "kubeconfig → ~/.kube/config"
  kubectl get nodes -o wide
}

cmd_build() {
  pick_kubectl
  step "build images (tag ${IMAGE_TAG})"
  local s
  for s in "${SERVICES[@]}"; do
    docker build -t "microsvc/${s}:${IMAGE_TAG}" "${ROOT}/${s}"
    ok "built microsvc/${s}:${IMAGE_TAG} ($(docker image inspect -f '{{.Size}}' "microsvc/${s}:${IMAGE_TAG}" | awk '{printf "%.0f MB", $1/1048576}'))"
  done
  step "import into k3s containerd"
  for s in "${SERVICES[@]}"; do
    docker save "microsvc/${s}:${IMAGE_TAG}" | sudo k3s ctr images import - >/dev/null
    ok "imported microsvc/${s}:${IMAGE_TAG}"
  done
  sudo k3s crictl images | grep microsvc || true
}

ensure_secret() {
  if [[ -z "${DB_PASSWORD}" ]]; then
    if k -n "${NAMESPACE}" get secret db-credentials >/dev/null 2>&1; then ok "secret exists (DB_PASSWORD not set — keeping it)"; return; fi
    DB_PASSWORD="$(openssl rand -hex 16)"
    warn "DB_PASSWORD not set — generated a random one (stored only in the Secret)"
  fi
  k -n "${NAMESPACE}" create secret generic db-credentials \
    --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
    --from-literal=DATABASE_URL="postgresql://app:${DB_PASSWORD}@postgres:5432/microsvc?sslmode=disable" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  ok "secret db-credentials applied"
}

cmd_deploy() {
  pick_kubectl
  step "deploy to namespace ${NAMESPACE}"
  k apply -f "${ROOT}/k8s/namespace.yaml"
  ensure_secret
  k apply -k "${ROOT}/k8s"
  # same tag, new image content → force new pods
  k -n "${NAMESPACE}" rollout restart deployment api worker web >/dev/null
  step "wait for rollouts"
  k -n "${NAMESPACE}" rollout status statefulset/postgres --timeout=180s
  local d
  for d in api worker web; do k -n "${NAMESPACE}" rollout status "deployment/${d}" --timeout=180s; done
  ok "all workloads ready"
}

cmd_smoke() {
  step "smoke test via Traefik Ingress (http://127.0.0.1)"
  local i body id status
  for i in $(seq 1 20); do
    body=$(curl -fsS --max-time 3 http://127.0.0.1/api/health 2>/dev/null) && break
    sleep 3
  done
  [[ -n "${body:-}" ]] || die "API not reachable through the Ingress"
  ok "health: ${body}"
  curl -fsS http://127.0.0.1/ | grep -q '<div id="root">' && ok "web UI served" || die "web UI not served"
  id=$(curl -fsS -X POST http://127.0.0.1/api/jobs -H 'Content-Type: application/json' \
        -d '{"input":"smoke test from cluster_bootstrap.sh running on k3s"}' | sed -nE 's/.*"id":([0-9]+).*/\1/p')
  [[ -n "${id}" ]] || die "could not create a job"
  ok "created job ${id}; waiting for a worker…"
  for i in $(seq 1 30); do
    status=$(curl -fsS "http://127.0.0.1/api/jobs/${id}" | sed -nE 's/.*"status":"([a-z]+)".*/\1/p')
    [[ "${status}" == done ]] && { ok "job ${id} processed by $(curl -fsS "http://127.0.0.1/api/jobs/${id}" | sed -nE 's/.*"processed_by":"([^"]+)".*/\1/p')"; return 0; }
    sleep 1
  done
  die "job ${id} still '${status}' after 30 s — check: kubectl -n ${NAMESPACE} logs deploy/worker"
}

cmd_status() {
  pick_kubectl
  step "cluster";   k get nodes -o wide
  step "workloads"; k -n "${NAMESPACE}" get pods -o wide
  step "services / ingress / hpa / pvc"
  k -n "${NAMESPACE}" get svc,ingress,hpa,pvc
  step "resource usage"; k -n "${NAMESPACE}" top pods 2>/dev/null || warn "metrics not ready yet"
  step "recent warning events"
  k -n "${NAMESPACE}" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -n 10 || true
}

cmd_scale_worker() {
  pick_kubectl
  local n=${1:?usage: scale-worker N}
  [[ "${n}" =~ ^[0-9]+$ ]] || die "N must be a number"
  k -n "${NAMESPACE}" scale deployment/worker --replicas="${n}"
  k -n "${NAMESPACE}" rollout status deployment/worker --timeout=120s
}

cmd_destroy() {
  pick_kubectl
  step "delete namespace ${NAMESPACE} (PVC data is deleted too)"
  read -r -p "Type the namespace name to confirm: " ans
  [[ "${ans}" == "${NAMESPACE}" ]] || die "aborted"
  k delete namespace "${NAMESPACE}" --wait=true
}

cmd_uninstall() {
  step "uninstall k3s"
  [[ -x /usr/local/bin/k3s-uninstall.sh ]] || die "k3s-uninstall.sh not found"
  sudo /usr/local/bin/k3s-uninstall.sh
}

case "${1:-}" in
  preflight)    cmd_preflight ;;
  install)      cmd_install ;;
  build)        cmd_build ;;
  deploy)       cmd_deploy ;;
  smoke)        cmd_smoke ;;
  status)       cmd_status ;;
  scale-worker) shift; cmd_scale_worker "$@" ;;
  destroy)      cmd_destroy ;;
  uninstall)    cmd_uninstall ;;
  all)          cmd_preflight; cmd_install; cmd_build; cmd_deploy; cmd_smoke; cmd_status ;;
  *)            usage; exit 2 ;;
esac

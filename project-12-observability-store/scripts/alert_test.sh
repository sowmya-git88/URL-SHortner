#!/usr/bin/env bash
# =============================================================================
# alert_test.sh — prove that Prometheus alert rules actually fire (and resolve)
# Project 12 · linux-devops-13-projects
#
#   scripts/alert_test.sh check            # promtool: validate config + rules, hot-reload Prometheus
#   scripts/alert_test.sh list             # current alerts (inactive/pending/firing)
#   scripts/alert_test.sh down             # stop store-app        → StoreAppDown must fire
#   scripts/alert_test.sh errors           # flood /api/chaos/error → HighHttpErrorRate must fire
#   scripts/alert_test.sh latency          # flood /api/chaos/slow  → SlowRequestsP95 must fire
#   scripts/alert_test.sh cpu              # burn every CPU core    → HostHighCpu must fire
#   scripts/alert_test.sh all              # check + down + errors + cpu, prints a PASS/FAIL table
#
# Env: PROM_URL (http://127.0.0.1:9090)  APP_URL (http://127.0.0.1:8080)  TIMEOUT (240 s)
# Requires: docker compose, curl, jq.  Run from the project directory.
# =============================================================================
set -euo pipefail

PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
APP_URL="${APP_URL:-http://127.0.0.1:8080}"
TIMEOUT="${TIMEOUT:-240}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

declare -a LOAD_PIDS=()
declare -A RESULTS=()

c() { printf '\e[%sm%s\e[0m' "$1" "$2"; }
log() { printf '%s %s\n' "$(date +%T)" "$*"; }
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

for bin in docker curl jq; do command -v "${bin}" >/dev/null || { echo "missing ${bin}" >&2; exit 2; }; done

stop_load() {
  local p
  for p in "${LOAD_PIDS[@]:-}"; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done
  LOAD_PIDS=()
  wait 2>/dev/null || true
}

cleanup() {
  stop_load
  # never leave the app stopped
  if [[ "$(docker compose ps -q store-app 2>/dev/null)" == "" ]] || ! docker compose ps --status running -q store-app | grep -q .; then
    docker compose start store-app >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# alert_state NAME → prints firing|pending|inactive
alert_state() {
  curl -fsS "${PROM_URL}/api/v1/alerts" \
    | jq -r --arg n "$1" '[.data.alerts[] | select(.labels.alertname == $n) | .state] | if length == 0 then "inactive" elif index("firing") then "firing" else .[0] end'
}

# wait_for NAME WANT_STATE → 0 when reached within TIMEOUT
wait_for() {
  local name=$1 want=$2 start state last=""
  start=$(date +%s)
  while (( $(date +%s) - start < TIMEOUT )); do
    state=$(alert_state "${name}" 2>/dev/null || echo "unknown")
    if [[ "${state}" != "${last}" ]]; then log "  ${name}: ${state}"; last=${state}; fi
    [[ "${state}" == "${want}" ]] && { log "  ${name} reached '${want}' after $(( $(date +%s) - start ))s"; return 0; }
    sleep 5
  done
  log "  timeout: ${name} never reached '${want}' (last: ${last})"
  return 1
}

record() { RESULTS["$1"]=$2; }

cmd_check() {
  log "promtool check config + rules (inside the prometheus container)"
  docker compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml
  docker compose exec -T prometheus promtool check rules /etc/prometheus/alert.rules.yml
  log "hot reload: POST /-/reload"
  curl -fsS -X POST "${PROM_URL}/-/reload" && log "reloaded"
  log "scrape targets:"
  curl -fsS "${PROM_URL}/api/v1/targets" | jq -r '.data.activeTargets[] | "  \(.labels.job)\t\(.health)\t\(.lastError)"'
  record check PASS
}

cmd_list() {
  curl -fsS "${PROM_URL}/api/v1/rules?type=alert" \
    | jq -r '.data.groups[].rules[] | "\(.state)\t\(.name)\t\(.labels.severity // "-")"' | sort | column -t
}

cmd_down() {
  log "TEST down: stopping store-app"
  docker compose stop store-app >/dev/null
  if wait_for StoreAppDown firing; then record down-fire PASS; else record down-fire FAIL; fi
  log "starting store-app again"
  docker compose start store-app >/dev/null
  if wait_for StoreAppDown inactive; then record down-resolve PASS; else record down-resolve FAIL; fi
}

flood() {   # flood PATH PARALLEL
  local path=$1 par=$2 i
  for (( i=0; i<par; i++ )); do
    ( while :; do curl -s -o /dev/null --max-time 5 "${APP_URL}${path}"; done ) &
    LOAD_PIDS+=("$!")
  done
  # some healthy traffic too, so the ratio is meaningful
  ( while :; do curl -s -o /dev/null "${APP_URL}/api/products"; sleep 0.5; done ) &
  LOAD_PIDS+=("$!")
}

cmd_errors() {
  log "TEST errors: flooding /api/chaos/error"
  flood /api/chaos/error 4
  if wait_for HighHttpErrorRate firing; then record errors-fire PASS; else record errors-fire FAIL; fi
  stop_load
  if wait_for HighHttpErrorRate inactive; then record errors-resolve PASS; else record errors-resolve FAIL; fi
}

cmd_latency() {
  log "TEST latency: flooding /api/chaos/slow"
  flood /api/chaos/slow 6
  if wait_for SlowRequestsP95 firing; then record latency-fire PASS; else record latency-fire FAIL; fi
  stop_load
}

cmd_cpu() {
  local cores i
  cores=$(nproc)
  log "TEST cpu: burning ${cores} core(s) with busy loops (watch: top)"
  for (( i=0; i<cores; i++ )); do
    ( while :; do :; done ) &
    LOAD_PIDS+=("$!")
  done
  if wait_for HostHighCpu firing; then record cpu-fire PASS; else record cpu-fire FAIL; fi
  stop_load
  if wait_for HostHighCpu inactive; then record cpu-resolve PASS; else record cpu-resolve FAIL; fi
}

summary() {
  (( ${#RESULTS[@]} )) || return 0
  echo; echo "──── alert test summary ────"
  local k failed=0
  for k in $(printf '%s\n' "${!RESULTS[@]}" | sort); do
    if [[ "${RESULTS[$k]}" == PASS ]]; then printf '  %-16s %s\n' "${k}" "$(c 32 PASS)"; else printf '  %-16s %s\n' "${k}" "$(c 31 FAIL)"; failed=1; fi
  done
  return "${failed}"
}

curl -fsS "${PROM_URL}/-/ready" >/dev/null || { echo "Prometheus not reachable at ${PROM_URL} (docker compose up -d ?)" >&2; exit 2; }

case "${1:-}" in
  check)   cmd_check ;;
  list)    cmd_list ;;
  down)    cmd_down ;;
  errors)  cmd_errors ;;
  latency) cmd_latency ;;
  cpu)     cmd_cpu ;;
  all)     cmd_check; cmd_down; cmd_errors; cmd_cpu ;;
  *)       usage; exit 2 ;;
esac
summary

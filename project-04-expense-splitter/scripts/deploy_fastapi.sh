#!/usr/bin/env bash
# =============================================================================
# deploy_fastapi.sh — repeatable deploy of the FastAPI app with automatic rollback
# Project 04 · linux-devops-13-projects
#
#   sudo scripts/deploy_fastapi.sh [--src DIR] [--skip-migrate] [--with-caddy] [--dry-run]
#
# Flow:
#   preflight → snapshot current code (app.prev) → rsync new code → venv + pip
#   → migrations → restart service → health check (retry) → reload Caddy
#   On any failure after the snapshot: restore app.prev, restart, exit non-zero.
# =============================================================================
set -Eeuo pipefail

APP=expense
APP_USER=expense
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ROOT=/opt/${APP}
ENV_FILE=/etc/${APP}/${APP}.env
SERVICE=${APP}.service
HEALTH_URL=http://127.0.0.1:5004/api/health
HEALTH_TRIES=20
SKIP_MIGRATE=0
WITH_CADDY=0
DRY_RUN=0
SNAPSHOT_TAKEN=0
START_TS=$(date +%s)

c_info=$'\e[36m'; c_ok=$'\e[32m'; c_err=$'\e[31m'; c_off=$'\e[0m'
[[ -t 2 ]] || { c_info=""; c_ok=""; c_err=""; c_off=""; }
info() { printf '%s[deploy]%s %s\n' "${c_info}" "${c_off}" "$*" >&2; }
ok()   { printf '%s[  ok  ]%s %s\n' "${c_ok}" "${c_off}" "$*" >&2; }
err()  { printf '%s[ fail ]%s %s\n' "${c_err}" "${c_off}" "$*" >&2; }
run()  { if (( DRY_RUN )); then echo "[dry-run] $*" >&2; else "$@"; fi; }

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case "$1" in
    --src)          SRC="$(cd "${2:?}" && pwd)"; shift 2 ;;
    --skip-migrate) SKIP_MIGRATE=1; shift ;;
    --with-caddy)   WITH_CADDY=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

rollback() {
  local code=$?
  trap - ERR
  err "deployment failed (exit ${code})"
  if (( SNAPSHOT_TAKEN )) && (( ! DRY_RUN )); then
    err "rolling back to previous code in ${APP_ROOT}/api.prev"
    rm -rf "${APP_ROOT}/api.failed"
    mv "${APP_ROOT}/api" "${APP_ROOT}/api.failed" 2>/dev/null || true
    cp -a "${APP_ROOT}/api.prev" "${APP_ROOT}/api"
    systemctl restart "${SERVICE}" || true
    sleep 3
    if curl -fsS --max-time 5 "${HEALTH_URL}" >/dev/null; then
      ok "rollback healthy — failed code kept in ${APP_ROOT}/api.failed for inspection"
    else
      err "rollback ALSO unhealthy — check: journalctl -u ${SERVICE} -n 50"
    fi
  fi
  journalctl -u "${SERVICE}" -n 25 --no-pager >&2 || true
  exit "${code}"
}
trap rollback ERR

preflight() {
  info "preflight"
  [[ ${EUID} -eq 0 ]] || { err "run with sudo"; exit 1; }
  [[ -f "${SRC}/api/main.py" ]] || { err "no api/main.py under ${SRC}"; exit 1; }
  id "${APP_USER}" &>/dev/null || { err "user ${APP_USER} missing (see GUIDEBOOK C2)"; exit 1; }
  [[ -f "${ENV_FILE}" ]] || { err "${ENV_FILE} missing"; exit 1; }
  local perm owner
  perm=$(stat -c '%a' "${ENV_FILE}"); owner=$(stat -c '%U:%G' "${ENV_FILE}")
  if [[ "${perm}" != "640" && "${perm}" != "600" ]]; then
    err "${ENV_FILE} has mode ${perm}; expected 640 — fixing"; run chmod 640 "${ENV_FILE}"
  fi
  [[ "${owner}" == "root:${APP_USER}" ]] || { info "fixing owner ${owner} → root:${APP_USER}"; run chown "root:${APP_USER}" "${ENV_FILE}"; }
  for bin in python3 rsync curl; do command -v "${bin}" >/dev/null || { err "missing ${bin}"; exit 1; }; done
  local avail_mb; avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  (( avail_mb > 120 )) || info "WARNING: only ${avail_mb} MB RAM available — pip may be slow (swap in use)"
  ok "preflight passed (src=${SRC})"
}

snapshot() {
  if [[ -d "${APP_ROOT}/api" ]]; then
    info "snapshot current code → api.prev"
    run rm -rf "${APP_ROOT}/api.prev"
    run cp -a "${APP_ROOT}/api" "${APP_ROOT}/api.prev"
    SNAPSHOT_TAKEN=1
  else
    info "first deploy — no snapshot"
  fi
}

sync_code() {
  info "sync code → ${APP_ROOT}"
  run install -d -m 0755 -o root -g "${APP_USER}" "${APP_ROOT}" "${APP_ROOT}/api" "${APP_ROOT}/web"
  run rsync -a --delete --exclude '__pycache__' --exclude '.venv' "${SRC}/api/" "${APP_ROOT}/api/"
  run rsync -a --delete "${SRC}/web/" "${APP_ROOT}/web/"
  run chown -R "root:${APP_USER}" "${APP_ROOT}/api"
  run chmod -R u=rwX,g=rX,o= "${APP_ROOT}/api"
  run chown -R root:root "${APP_ROOT}/web"
  run chmod -R u=rwX,go=rX "${APP_ROOT}/web"
  ok "code synced"
}

python_env() {
  local venv="${APP_ROOT}/venv"
  if [[ ! -x "${venv}/bin/python" ]]; then
    info "creating virtualenv"
    run python3 -m venv "${venv}"
  fi
  local req_hash_file="${venv}/.requirements.sha256" new_hash old_hash=""
  new_hash=$(sha256sum "${APP_ROOT}/api/requirements.txt" | cut -d' ' -f1)
  [[ -f "${req_hash_file}" ]] && old_hash=$(cat "${req_hash_file}")
  if [[ "${new_hash}" != "${old_hash}" ]]; then
    info "requirements changed → pip install"
    run "${venv}/bin/pip" install --no-cache-dir --upgrade pip -q
    run "${venv}/bin/pip" install --no-cache-dir -q -r "${APP_ROOT}/api/requirements.txt"
    (( DRY_RUN )) || echo "${new_hash}" > "${req_hash_file}"
  else
    info "requirements unchanged → skip pip"
  fi
  run chown -R "root:${APP_USER}" "${venv}"
  ok "virtualenv ready"
}

migrate() {
  (( SKIP_MIGRATE )) && { info "migrations skipped"; return; }
  info "running migrations as ${APP_USER}"
  run systemd-run --quiet --wait --pipe --collect \
      --uid="${APP_USER}" --gid="${APP_USER}" \
      -p EnvironmentFile="${ENV_FILE}" -p WorkingDirectory="${APP_ROOT}/api" \
      "${APP_ROOT}/venv/bin/python" migrate.py
  ok "migrations applied"
}

restart_and_check() {
  info "installing unit + restarting ${SERVICE}"
  run install -m 0644 "${SRC}/deploy/${APP}.service" "/etc/systemd/system/${SERVICE}"
  run systemctl daemon-reload
  run systemctl enable "${SERVICE}" --quiet
  run systemctl restart "${SERVICE}"
  (( DRY_RUN )) && return
  local i
  for (( i=1; i<=HEALTH_TRIES; i++ )); do
    if curl -fsS --max-time 4 "${HEALTH_URL}" -o /tmp/expense-health.json; then
      ok "healthy after ${i} tries: $(cat /tmp/expense-health.json)"
      rm -f /tmp/expense-health.json
      return 0
    fi
    sleep 1.5
  done
  err "health check failed after ${HEALTH_TRIES} tries"
  return 1
}

reload_caddy() {
  (( WITH_CADDY )) || return 0
  info "validating + reloading Caddy"
  run install -m 0644 "${SRC}/deploy/Caddyfile" /etc/caddy/Caddyfile.new
  if (( ! DRY_RUN )); then
    # shellcheck disable=SC2046
    env $(cat /etc/caddy/caddy.env) caddy validate --config /etc/caddy/Caddyfile.new --adapter caddyfile
    mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile
    systemctl reload caddy
  fi
  ok "caddy reloaded"
}

main() {
  preflight
  snapshot
  sync_code
  python_env
  migrate
  restart_and_check
  reload_caddy
  ok "deploy finished in $(( $(date +%s) - START_TS ))s"
}

main

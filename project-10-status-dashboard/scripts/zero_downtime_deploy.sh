#!/usr/bin/env bash
# =============================================================================
# zero_downtime_deploy.sh — blue/green deploys with health-gated cut-over and
#                           instant rollback for the Bun status dashboard
# Project 10 · linux-devops-13-projects
#
#   sudo zero_downtime_deploy.sh deploy /home/deploy/incoming/statusdash-<sha>.tgz <version>
#   sudo zero_downtime_deploy.sh rollback
#   sudo zero_downtime_deploy.sh status
#
# Layout:
#   /opt/statusdash/releases/<UTC-ts>-<version>/{server,web/dist,VERSION}
#   /opt/statusdash/blue  -> releases/...      (statusdash@blue  on :5010)
#   /opt/statusdash/green -> releases/...      (statusdash@green on :5011)
#   /opt/statusdash/state/active               ("blue" | "green")
#
# Deploy: unpack → migrate → point IDLE colour at new release → start idle →
#         health-check (must report the new version) → mark active → stop old colour.
#         The old colour's symlink is left untouched = instant rollback target.
# Owned by root:root 0755 — the deploy user can run it via sudo but never modify it.
# =============================================================================
set -Eeuo pipefail
umask 022

BASE=/opt/statusdash
RELEASES=${BASE}/releases
STATE=${BASE}/state
APP_USER=statusdash
ENV_FILE=/etc/statusdash/statusdash.env
INCOMING_DIR=/home/deploy/incoming
KEEP_RELEASES=5
HEALTH_TIMEOUT=40
declare -A PORT=([blue]=5010 [green]=5011)

log()  { printf '%s [deploy] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; logger -t zero_downtime_deploy -- "$*" 2>/dev/null || true; }
die()  { log "ERROR: $*"; exit 1; }
usage(){ sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

[[ ${EUID} -eq 0 ]] || die "must run as root (via sudo)"
install -d -m 0755 "${RELEASES}" "${STATE}"
exec 9>"${STATE}/.lock"
flock -n 9 || die "another deploy is in progress"

other()   { [[ "$1" == "blue" ]] && echo green || echo blue; }
active()  { cat "${STATE}/active" 2>/dev/null || echo none; }
target()  { readlink -f "${BASE}/$1" 2>/dev/null || echo "-"; }

# health COLOR [EXPECTED_VERSION] → waits until /api/health is 200 (and version matches)
health() {
  local color=$1 want=${2:-} deadline body ver
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    if body=$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT[$color]}/api/health" 2>/dev/null); then
      ver=$(printf '%s' "${body}" | sed -nE 's/.*"version":"([^"]*)".*/\1/p')
      if [[ -z "${want}" || "${ver}" == "${want}" ]]; then
        log "${color} healthy (version ${ver})"; return 0
      fi
      log "${color} answers but reports version '${ver}', want '${want}'"
    fi
    sleep 1
  done
  return 1
}

swap_link() {   # atomic symlink replacement: create tmp link, rename over the old one
  local color=$1 dest=$2
  ln -sfn "${dest}" "${BASE}/.${color}.tmp"
  mv -Tf "${BASE}/.${color}.tmp" "${BASE}/${color}"
}

prune() {
  local keep_a keep_b r n=0
  keep_a=$(target blue); keep_b=$(target green)
  while IFS= read -r r; do
    n=$(( n + 1 ))
    [[ "${r}" == "${keep_a}" || "${r}" == "${keep_b}" ]] && continue
    (( n <= KEEP_RELEASES )) && continue
    log "prune ${r}"; rm -rf -- "${r}"
  done < <(find "${RELEASES}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
}

cmd_deploy() {
  local tarball=${1:-} version=${2:-}
  # ---- strict argument validation (sudoers allows 'deploy *') ----
  [[ "${version}" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || die "invalid version '${version}'"
  [[ "${tarball}" =~ ^${INCOMING_DIR}/statusdash-[A-Za-z0-9._-]+\.tgz$ ]] || die "tarball must be ${INCOMING_DIR}/statusdash-*.tgz"
  [[ -f "${tarball}" && ! -L "${tarball}" ]] || die "no such regular file ${tarball}"

  local cur idle rel prev_idle_target
  cur=$(active)
  idle=$([[ "${cur}" == "none" ]] && echo blue || other "${cur}")
  rel="${RELEASES}/$(date -u +%Y%m%dT%H%M%SZ)-${version}"
  log "deploy ${version}: active=${cur} idle=${idle} release=${rel}"

  # ---- 1. unpack (refuse absolute paths / .. in the archive) ----
  if tar -tzf "${tarball}" | grep -qE '(^/|(^|/)\.\.(/|$))'; then die "unsafe paths in tarball"; fi
  install -d -m 0755 "${rel}"
  tar -xzf "${tarball}" -C "${rel}" --no-same-owner
  [[ -f "${rel}/server/server.ts" && -d "${rel}/server/node_modules" && -f "${rel}/web/dist/index.html" ]] \
    || { rm -rf "${rel}"; die "tarball missing server/server.ts, server/node_modules or web/dist"; }
  printf '%s\n' "${version}" > "${rel}/VERSION"
  chown -R root:"${APP_USER}" "${rel}"
  chmod -R u=rwX,g=rX,o= "${rel}"

  # ---- 2. migrations (must be backward compatible: old colour keeps running!) ----
  log "running migrations"
  systemd-run --quiet --wait --pipe --collect --uid="${APP_USER}" --gid="${APP_USER}" \
    -p EnvironmentFile="${ENV_FILE}" -p WorkingDirectory="${rel}/server" -E HOME=/tmp \
    /usr/local/bin/bun run migrate.ts || { rm -rf "${rel}"; die "migration failed — nothing switched"; }

  # ---- 3. start the idle colour on the new release ----
  prev_idle_target=$(target "${idle}")
  swap_link "${idle}" "${rel}"
  systemctl restart "statusdash@${idle}"
  if ! health "${idle}" "${version}"; then
    log "new release unhealthy — aborting; ${cur} keeps serving"
    journalctl -u "statusdash@${idle}" -n 30 --no-pager >&2 || true
    systemctl stop "statusdash@${idle}" || true
    [[ "${prev_idle_target}" != "-" ]] && swap_link "${idle}" "${prev_idle_target}"
    exit 1
  fi

  # ---- 4. cut over: record state, then gracefully stop the old colour ----
  echo "${idle}" > "${STATE}/active"
  echo "${cur}"  > "${STATE}/previous"
  if [[ "${cur}" != "none" ]]; then
    log "stopping ${cur} (SIGTERM → drains in-flight requests; Caddy fails over to ${idle})"
    systemctl stop "statusdash@${cur}"
  fi
  systemctl enable "statusdash@${idle}" --quiet
  [[ "${cur}" != "none" ]] && systemctl disable "statusdash@${cur}" --quiet || true

  rm -f -- "${tarball}"
  prune
  log "✅ ${version} live on ${idle} (:${PORT[$idle]}). Rollback target: ${cur} → $(target "${cur}")"
}

cmd_rollback() {
  local cur prev
  cur=$(active)
  [[ "${cur}" != "none" ]] || die "nothing deployed yet"
  prev=$(other "${cur}")
  [[ -L "${BASE}/${prev}" && -d "$(target "${prev}")" ]] || die "${prev} has no release to roll back to"
  log "rollback: ${cur} → ${prev} ($(target "${prev}"))"
  systemctl start "statusdash@${prev}"
  health "${prev}" "$(cat "$(target "${prev}")/VERSION")" || die "rollback target unhealthy — ${cur} still serving"
  echo "${prev}" > "${STATE}/active"
  echo "${cur}"  > "${STATE}/previous"
  systemctl stop "statusdash@${cur}"
  systemctl enable "statusdash@${prev}" --quiet
  systemctl disable "statusdash@${cur}" --quiet || true
  log "✅ rolled back; ${prev} serving $(cat "$(target "${prev}")/VERSION")"
}

cmd_status() {
  local c
  echo "active: $(active)   previous: $(cat "${STATE}/previous" 2>/dev/null || echo -)"
  for c in blue green; do
    printf '%-6s port %-5s unit %-9s release %s\n' "${c}" "${PORT[$c]}" \
      "$(systemctl is-active "statusdash@${c}" 2>/dev/null || true)" "$(target "${c}")"
    curl -fsS --max-time 2 "http://127.0.0.1:${PORT[$c]}/api/health" 2>/dev/null | sed 's/^/        /' || echo "        (not answering)"
  done
  echo "releases:"; ls -1t "${RELEASES}" 2>/dev/null | head -n 10 | sed 's/^/  /'
}

case "${1:-}" in
  deploy)   shift; cmd_deploy "$@" ;;
  rollback) cmd_rollback ;;
  status)   cmd_status ;;
  *)        usage; exit 2 ;;
esac

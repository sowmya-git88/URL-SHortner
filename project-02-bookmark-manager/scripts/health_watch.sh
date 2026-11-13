#!/usr/bin/env bash
# =============================================================================
# health_watch.sh — watchdog for a process started WITHOUT systemd (nohup era)
# Project 02 · linux-devops-13-projects
#
#   health_watch.sh [--once|--loop] [options]
#
# Every interval it checks:
#   1. is the process alive?            (pgrep -x)
#   2. does /api/health answer 200?     (curl with timeout)
#   3. is RSS memory under the limit?   (/proc/<pid>/status VmRSS)
# After N consecutive failures it restarts the app:
#   SIGTERM -> wait for graceful exit -> SIGKILL if still alive -> nohup start
# =============================================================================
set -euo pipefail

PROCESS_NAME="${PROCESS_NAME:-bookmarks}"
APP_USER="${APP_USER:-bookmarks}"
BINARY="${BINARY:-/opt/bookmarks/bin/bookmarks}"
ENV_FILE="${ENV_FILE:-/etc/bookmarks/bookmarks.env}"
APP_LOG="${APP_LOG:-/var/log/bookmarks/app.log}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:5002/api/health}"
WATCH_LOG="${WATCH_LOG:-/var/log/bookmarks/health_watch.log}"
LOCK_FILE="${LOCK_FILE:-/run/lock/health_watch.${PROCESS_NAME}.lock}"
INTERVAL="${INTERVAL:-15}"
MAX_FAILS="${MAX_FAILS:-3}"
MAX_RSS_MB="${MAX_RSS_MB:-120}"
GRACE_SECONDS="${GRACE_SECONDS:-10}"
MODE="loop"
NO_RESTART=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--once|--loop] [--interval S] [--max-fails N] [--max-rss-mb MB] [--no-restart]

Environment overrides: PROCESS_NAME APP_USER BINARY ENV_FILE APP_LOG HEALTH_URL WATCH_LOG
Exit codes (--once): 0 healthy, 1 unhealthy, 2 usage/config error
EOF
}

ts()  { date -u +%FT%TZ; }
log() { printf '%s [%s] %s\n' "$(ts)" "$1" "$2" | tee -a "${WATCH_LOG}"; }

parse_args() {
  while (( $# )); do
    case "$1" in
      --once)        MODE="once"; shift ;;
      --loop)        MODE="loop"; shift ;;
      --interval)    INTERVAL="${2:?}"; shift 2 ;;
      --max-fails)   MAX_FAILS="${2:?}"; shift 2 ;;
      --max-rss-mb)  MAX_RSS_MB="${2:?}"; shift 2 ;;
      --no-restart)  NO_RESTART=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [[ "${INTERVAL}" =~ ^[0-9]+$ && "${MAX_FAILS}" =~ ^[0-9]+$ && "${MAX_RSS_MB}" =~ ^[0-9]+$ ]] \
    || { echo "numeric options expected" >&2; exit 2; }
}

get_pid() {
  # -x exact name match, -o oldest (the parent if several)
  pgrep -x -o "${PROCESS_NAME}" || true
}

rss_mb() {
  local pid=$1
  awk '/^VmRSS:/ {printf "%d", $2/1024}' "/proc/${pid}/status" 2>/dev/null || echo 0
}

check_http() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "${HEALTH_URL}" || true)"
  [[ "${code}" == "200" ]]
}

stop_app() {
  local pid=$1 waited=0
  log WARN "sending SIGTERM to pid ${pid} (graceful drain)"
  kill -TERM "${pid}" 2>/dev/null || return 0
  while kill -0 "${pid}" 2>/dev/null; do
    if (( waited >= GRACE_SECONDS )); then
      log WARN "pid ${pid} ignored SIGTERM for ${GRACE_SECONDS}s -> SIGKILL"
      kill -KILL "${pid}" 2>/dev/null || true
      break
    fi
    sleep 1; (( waited += 1 ))
  done
}

start_app() {
  [[ -x "${BINARY}" ]] || { log ERROR "binary ${BINARY} not executable"; return 1; }
  [[ -r "${ENV_FILE}" ]] || { log ERROR "cannot read ${ENV_FILE}"; return 1; }
  log INFO "starting ${BINARY} as ${APP_USER} with nohup"
  # set -a exports every variable sourced from the env file into the child.
  # setsid detaches from our session so the app survives this script exiting.
  if [[ "$(id -un)" == "${APP_USER}" ]]; then
    ( set -a; . "${ENV_FILE}"; set +a; setsid nohup "${BINARY}" >>"${APP_LOG}" 2>&1 < /dev/null & )
  else
    runuser -u "${APP_USER}" -- bash -c \
      "set -a; . '${ENV_FILE}'; set +a; setsid nohup '${BINARY}' >>'${APP_LOG}' 2>&1 < /dev/null &"
  fi
  sleep 2
  local pid; pid="$(get_pid)"
  [[ -n "${pid}" ]] && log INFO "started pid ${pid}" || { log ERROR "start failed, see ${APP_LOG}"; return 1; }
}

restart_app() {
  if (( NO_RESTART )); then log WARN "restart suppressed (--no-restart)"; return 0; fi
  local pid; pid="$(get_pid)"
  [[ -n "${pid}" ]] && stop_app "${pid}"
  start_app
}

# One probe. Prints a status line; returns 0 healthy / 1 unhealthy.
probe() {
  local pid rss
  pid="$(get_pid)"
  if [[ -z "${pid}" ]]; then
    log ERROR "process '${PROCESS_NAME}' not running"; return 1
  fi
  rss="$(rss_mb "${pid}")"
  if (( rss > MAX_RSS_MB )); then
    log ERROR "pid ${pid} RSS ${rss}MB > limit ${MAX_RSS_MB}MB"; return 1
  fi
  if ! check_http; then
    log ERROR "pid ${pid} alive but ${HEALTH_URL} not 200"; return 1
  fi
  log OK "pid ${pid} rss=${rss}MB http=200"
  return 0
}

cleanup() { log INFO "watchdog stopping (signal received)"; exit 0; }

main() {
  parse_args "$@"
  mkdir -p "$(dirname "${WATCH_LOG}")" 2>/dev/null || true
  touch "${WATCH_LOG}" 2>/dev/null || WATCH_LOG=/dev/stderr

  if [[ "${MODE}" == "once" ]]; then
    probe && exit 0 || exit 1
  fi

  # Prevent two watchdogs fighting each other.
  exec 9>"${LOCK_FILE}"
  flock -n 9 || { echo "another health_watch is running (lock ${LOCK_FILE})" >&2; exit 2; }

  trap cleanup INT TERM
  log INFO "watching '${PROCESS_NAME}' every ${INTERVAL}s (max_fails=${MAX_FAILS}, max_rss=${MAX_RSS_MB}MB)"
  local fails=0
  while true; do
    if probe; then
      fails=0
    else
      (( fails += 1 ))
      log WARN "consecutive failures: ${fails}/${MAX_FAILS}"
      if (( fails >= MAX_FAILS )); then
        restart_app || log ERROR "restart attempt failed"
        fails=0
      fi
    fi
    sleep "${INTERVAL}" &
    wait $!          # 'wait' lets the trap fire immediately on SIGTERM
  done
}

main "$@"

#!/usr/bin/env bash
# =============================================================================
# service_audit.sh — audit systemd services: state, enablement, restarts,
#                    memory, uptime, listening ports and recent journal errors
# Project 03 · linux-devops-13-projects
#
#   service_audit.sh [--since "1 hour ago"] [--security] [--json] UNIT[:PORT] ...
#   service_audit.sh habits.service:5003 caddy.service:443 ssh.service:22
#
# Exit code: 0 all healthy · 1 at least one unit unhealthy · 2 usage error
# =============================================================================
set -euo pipefail

SINCE="1 hour ago"
SECURITY=0
JSON=0
declare -a TARGETS=()
declare -a JSON_ROWS=()
UNHEALTHY=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --since)    SINCE="${2:?}"; shift 2 ;;
      --security) SECURITY=1; shift ;;
      --json)     JSON=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      -*)         echo "unknown option $1" >&2; usage >&2; exit 2 ;;
      *)          TARGETS+=("$1"); shift ;;
    esac
  done
  if (( ${#TARGETS[@]} == 0 )); then
    TARGETS=(habits.service:5003 caddy.service:443 ssh.service:22)
  fi
}

# Colours only when stdout is a terminal (not in journald / pipes)
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

human_bytes() {
  local b=$1
  if [[ ! "${b}" =~ ^[0-9]+$ ]]; then echo "-"; return; fi
  awk -v b="${b}" 'BEGIN { split("B KB MB GB",u); i=1; while (b>=1024 && i<4) {b/=1024; i++}; printf "%.1f%s", b, u[i] }'
}

since_epoch() {
  # ExecMainStartTimestamp -> "3h12m" style uptime
  local ts=$1 start now diff
  [[ -z "${ts}" || "${ts}" == "n/a" ]] && { echo "-"; return; }
  start=$(date -d "${ts}" +%s 2>/dev/null) || { echo "-"; return; }
  now=$(date +%s); diff=$(( now - start ))
  printf '%dd%02dh%02dm' $(( diff/86400 )) $(( diff%86400/3600 )) $(( diff%3600/60 ))
}

port_listening() {
  local port=$1
  ss -Htln "sport = :${port}" 2>/dev/null | grep -q .
}

audit_unit() {
  local target=$1 unit port=""
  unit="${target%%:*}"
  [[ "${target}" == *:* ]] && port="${target##*:}"

  if ! systemctl cat "${unit}" &>/dev/null; then
    printf '%s%-22s%s %s\n' "${RED}" "${unit}" "${RESET}" "UNIT NOT FOUND"
    UNHEALTHY=1
    JSON_ROWS+=("{\"unit\":\"${unit}\",\"found\":false}")
    return
  fi

  # One systemctl call, many properties -> associative array
  declare -A p=()
  local key val
  while IFS='=' read -r key val; do
    p["${key}"]="${val}"
  done < <(systemctl show "${unit}" \
            -p ActiveState -p SubState -p UnitFileState -p NRestarts -p MainPID \
            -p MemoryCurrent -p ExecMainStartTimestamp -p Result -p ExecMainStatus)

  local active="${p[ActiveState]:-unknown}" sub="${p[SubState]:-?}"
  local enabled="${p[UnitFileState]:-?}" restarts="${p[NRestarts]:-0}"
  local mem; mem="$(human_bytes "${p[MemoryCurrent]:-}")"
  local up; up="$(since_epoch "${p[ExecMainStartTimestamp]:-}")"
  local errors
  errors="$(journalctl -u "${unit}" --since "${SINCE}" -p err --no-pager -q 2>/dev/null | wc -l)"

  local port_state="-"
  if [[ -n "${port}" ]]; then
    if port_listening "${port}"; then port_state="${port}:up"; else port_state="${port}:DOWN"; fi
  fi

  local verdict="OK" colour="${GREEN}"
  if [[ "${active}" != "active" ]]; then verdict="DOWN"; colour="${RED}"
  elif [[ "${port_state}" == *DOWN ]]; then verdict="NO-PORT"; colour="${RED}"
  elif (( restarts > 3 || errors > 0 )); then verdict="WARN"; colour="${YELLOW}"
  fi
  [[ "${verdict}" == "DOWN" || "${verdict}" == "NO-PORT" ]] && UNHEALTHY=1
  [[ "${enabled}" != "enabled" && "${enabled}" != "static" ]] && [[ "${verdict}" == "OK" ]] && { verdict="NOT-ENABLED"; colour="${YELLOW}"; }

  printf '%-22s %s%-11s%s %-10s %-9s %-8s %-9s %-11s %-6s %s\n' \
    "${unit}" "${colour}" "${verdict}" "${RESET}" "${active}/${sub}" "${enabled}" \
    "${restarts}" "${mem}" "${up}" "${errors}" "${port_state}"

  JSON_ROWS+=("{\"unit\":\"${unit}\",\"verdict\":\"${verdict}\",\"active\":\"${active}\",\"sub\":\"${sub}\",\"enabled\":\"${enabled}\",\"restarts\":${restarts:-0},\"memory\":\"${mem}\",\"uptime\":\"${up}\",\"errors\":${errors},\"port\":\"${port_state}\"}")

  if (( errors > 0 )) && (( ! JSON )); then
    echo "    └─ last errors since '${SINCE}':"
    journalctl -u "${unit}" --since "${SINCE}" -p err --no-pager -q -o short-iso 2>/dev/null \
      | tail -n 3 | sed 's/^/       /'
  fi

  if (( SECURITY )) && (( ! JSON )); then
    local score
    score="$(systemd-analyze security "${unit}" --no-pager 2>/dev/null | tail -n 1 || true)"
    echo "    └─ security: ${score:-n/a}"
  fi
}

main() {
  parse_args "$@"

  if (( JSON )); then
    exec 3>&1 1>/dev/null      # silence table output, keep fd3 for JSON
  fi

  echo "${BOLD}Service audit on $(hostname) at $(date -u +%FT%TZ) (errors since: ${SINCE})${RESET}"
  printf '%-22s %-11s %-10s %-9s %-8s %-9s %-11s %-6s %s\n' \
    UNIT VERDICT STATE ENABLED RESTARTS MEMORY UPTIME ERRORS PORT
  printf '%.0s─' {1..100}; echo

  local t
  for t in "${TARGETS[@]}"; do
    audit_unit "${t}"
  done

  echo
  local failed
  failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)"
  echo "System-wide failed units: ${failed:-none}"
  echo "Load: $(cut -d' ' -f1-3 /proc/loadavg) · $(free -m | awk '/Mem:/ {print "RAM avail "$7"MB/"$2"MB"}') · $(free -m | awk '/Swap:/ {print "swap used "$3"MB"}')"

  if (( JSON )); then
    local IFS=,
    printf '{"host":"%s","time":"%s","healthy":%s,"units":[%s]}\n' \
      "$(hostname)" "$(date -u +%FT%TZ)" "$([[ ${UNHEALTHY} -eq 0 ]] && echo true || echo false)" \
      "${JSON_ROWS[*]}" >&3
  fi
  exit "${UNHEALTHY}"
}

main "$@"

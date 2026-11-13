#!/usr/bin/env bash
# =============================================================================
# docker_health.sh — health report for a Docker Compose stack
# Project 11 · linux-devops-13-projects
#
#   scripts/docker_health.sh [-p PROJECT] [-u URL]... [--logs N] [--restart-unhealthy] [--watch SECONDS]
#
#   -p PROJECT            compose project name (default: $COMPOSE_PROJECT_NAME or "saas")
#   -u URL                extra HTTP endpoint(s) that must return 2xx (default: http://127.0.0.1/api/health)
#   --logs N              print the last N log lines of every unhealthy container (default 15)
#   --restart-unhealthy   docker restart containers whose healthcheck says "unhealthy"
#   --watch SECONDS       repeat forever (clear screen between runs)
#
# Checks: container state, healthcheck status + last probe output, restart count,
# OOMKilled flag, last exit code, CPU/MEM vs limit, networks (internal flag),
# volume sizes, HTTP endpoints. Exit 0 healthy · 1 problems found · 2 usage error
# =============================================================================
set -euo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-saas}"
declare -a URLS=()
LOG_LINES=15
RESTART=0
WATCH=0
PROBLEMS=0

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case "$1" in
    -p) PROJECT="${2:?}"; shift 2 ;;
    -u) URLS+=("${2:?}"); shift 2 ;;
    --logs) LOG_LINES="${2:?}"; shift 2 ;;
    --restart-unhealthy) RESTART=1; shift ;;
    --watch) WATCH="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
(( ${#URLS[@]} )) || URLS=("http://127.0.0.1/api/health")
command -v docker >/dev/null || { echo "docker not found" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "cannot talk to the Docker daemon (are you in the 'docker' group?)" >&2; exit 2; }

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else R=; G=; Y=; B=; N=; fi
problem() { PROBLEMS=1; printf '%s  ✗ %s%s\n' "${R}" "$*" "${N}"; }

human_age() {   # ISO timestamp → "2h13m"
  local s; s=$(( $(date +%s) - $(date -d "$1" +%s 2>/dev/null || date +%s) ))
  printf '%dd%02dh%02dm' $(( s/86400 )) $(( s%86400/3600 )) $(( s%3600/60 ))
}

report() {
  PROBLEMS=0
  local ids
  ids=$(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}")
  echo "${B}Docker health — project '${PROJECT}' — $(date '+%F %T')${N}"
  if [[ -z "${ids}" ]]; then problem "no containers for project ${PROJECT} (docker compose up -d ?)"; return; fi

  # One `docker stats` call for all running containers: name → "cpu|mem usage|mem %"
  declare -A STATS=()
  local name cpu mem memp
  while IFS='|' read -r name cpu mem memp; do
    STATS["${name}"]="${cpu}|${mem}|${memp}"
  done < <(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null || true)

  printf '\n%-22s %-10s %-10s %-9s %-4s %-4s %-5s %-8s %-26s %s\n' CONTAINER SERVICE STATE HEALTH RST OOM EXIT CPU "MEM (use / limit)" UPTIME
  printf '%.0s─' {1..120}; echo
  local id svc state health restarts oom exitc started colour s
  local -a unhealthy=()
  for id in ${ids}; do
    IFS='|' read -r name svc state health restarts oom exitc started < <(docker inspect --format \
      '{{.Name}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{.State.ExitCode}}|{{.State.StartedAt}}' "${id}")
    name=${name#/}
    s=${STATS[${name}]:-"-|-|-"}
    colour=${G}
    [[ "${health}" == "starting" ]] && colour=${Y}
    if [[ "${state}" != "running" || "${health}" == "unhealthy" || "${oom}" == "true" ]]; then colour=${R}; unhealthy+=("${name}"); fi
    printf '%s%-22s %-10s %-10s %-9s %-4s %-4s %-5s %-8s %-26s %s%s\n' "${colour}" "${name:0:22}" "${svc:0:10}" "${state}" "${health}" \
      "${restarts}" "$([[ ${oom} == true ]] && echo YES || echo no)" "${exitc}" "$(cut -d'|' -f1 <<<"${s}")" "$(cut -d'|' -f2 <<<"${s}")" \
      "$([[ ${state} == running ]] && human_age "${started}" || echo -)" "${N}"
    (( restarts > 3 )) && problem "${name}: restarted ${restarts} times (crash loop?)"
    [[ "${oom}" == "true" ]] && problem "${name}: was OOM-killed (exit 137) — raise deploy.resources.limits.memory or fix a leak"
  done

  echo; echo "${B}Healthcheck details for unhealthy/stopped containers${N}"
  if (( ${#unhealthy[@]} == 0 )); then echo "  none ✓"; fi
  for name in "${unhealthy[@]}"; do
    problem "${name}"
    docker inspect --format '{{if .State.Health}}{{range $i, $l := .State.Health.Log}}    probe exit={{$l.ExitCode}} {{printf "%.120s" $l.Output}}{{"\n"}}{{end}}{{end}}' "${name}" | tail -n 3
    echo "    --- last ${LOG_LINES} log lines ---"
    docker logs --tail "${LOG_LINES}" "${name}" 2>&1 | sed 's/^/    /'
    if (( RESTART )); then echo "    → docker restart ${name}"; docker restart "${name}" >/dev/null; fi
  done

  echo; echo "${B}Networks${N}"
  local net
  for net in $(docker network ls -q --filter "label=com.docker.compose.project=${PROJECT}"); do
    docker network inspect --format '  {{.Name}}  driver={{.Driver}}  internal={{.Internal}}  subnet={{range .IPAM.Config}}{{.Subnet}}{{end}}  containers={{len .Containers}}' "${net}"
  done

  echo; echo "${B}Volumes${N}"
  local vol mp size
  for vol in $(docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}"); do
    mp=$(docker volume inspect --format '{{.Mountpoint}}' "${vol}")
    size=$(sudo -n du -sh "${mp}" 2>/dev/null | cut -f1 || true)
    printf '  %-28s %s\n' "${vol}" "${size:-(run with sudo for size)}"
  done

  echo; echo "${B}Endpoints${N}"
  local u code
  for u in "${URLS[@]}"; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${u}" || echo 000)
    if [[ "${code}" =~ ^2 ]]; then echo "  ${G}✓ ${code} ${u}${N}"; else problem "${code} ${u}"; fi
  done

  echo; echo "${B}Disk used by Docker${N}"
  docker system df | sed 's/^/  /'
  echo
  (( PROBLEMS )) && echo "${R}${B}RESULT: problems found${N}" || echo "${G}${B}RESULT: all healthy${N}"
}

if (( WATCH > 0 )); then
  trap 'exit 0' INT TERM
  while true; do clear; report || true; sleep "${WATCH}"; done
fi
report
exit "${PROBLEMS}"

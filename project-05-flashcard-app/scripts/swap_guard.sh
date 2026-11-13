#!/usr/bin/env bash
# =============================================================================
# swap_guard.sh — create, tune and watch swap; detect and explain OOM kills
# Project 05 · linux-devops-13-projects
#
#   swap_guard.sh status                         # memory + swap + top RSS processes
#   sudo swap_guard.sh ensure [SIZE]             # create/enable /swapfile (default 2G), persist in fstab
#   sudo swap_guard.sh tune [SWAPPINESS]         # sysctl vm.swappiness (default 10) + vfs_cache_pressure
#   swap_guard.sh oom-report [SINCE]             # list OOM kills from the kernel log (default "24 hours ago")
#   swap_guard.sh watch [--interval S] [--min-avail-mb MB] [--max-swap-pct P] [--once]
#   sudo swap_guard.sh remove                    # swapoff + delete /swapfile + clean fstab
#
# watch exit codes (--once): 0 ok · 1 warning threshold crossed · 2 usage error
# =============================================================================
set -euo pipefail

SWAPFILE="${SWAPFILE:-/swapfile}"
SYSCTL_FILE="/etc/sysctl.d/99-swap-guard.conf"
LOG_TAG="swap_guard"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; logger -t "${LOG_TAG}" -p user.warning "$*" 2>/dev/null || true; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need_root() { [[ ${EUID} -eq 0 ]] || die "this subcommand needs sudo"; }

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- helpers reading /proc/meminfo (values in kB) ----
meminfo() { awk -v k="$1:" '$1==k {print $2}' /proc/meminfo; }
to_mb()   { echo $(( $1 / 1024 )); }

size_to_mb() {
  local s=${1^^}
  case "${s}" in
    *G) echo $(( ${s%G} * 1024 )) ;;
    *M) echo "${s%M}" ;;
    *) die "size must look like 2G or 512M (got $1)" ;;
  esac
}

cmd_status() {
  local total avail swap_total swap_free
  total=$(meminfo MemTotal); avail=$(meminfo MemAvailable)
  swap_total=$(meminfo SwapTotal); swap_free=$(meminfo SwapFree)
  say "=== memory ($(hostname), $(date -u +%FT%TZ)) ==="
  free -h
  say ""
  say "MemAvailable : $(to_mb "${avail}") MB of $(to_mb "${total}") MB ($(( avail * 100 / total ))%)"
  if (( swap_total > 0 )); then
    say "Swap used    : $(to_mb $(( swap_total - swap_free ))) MB of $(to_mb "${swap_total}") MB ($(( (swap_total - swap_free) * 100 / swap_total ))%)"
  else
    say "Swap         : NONE configured  ← builds (npm, vite, go, cargo) will likely be OOM-killed"
  fi
  say "swappiness   : $(cat /proc/sys/vm/swappiness)   vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure)"
  say ""
  say "=== swap devices ==="
  swapon --show 2>/dev/null || true
  say ""
  say "=== top 8 processes by RSS ==="
  ps -eo pid,user,rss,comm --sort=-rss | head -n 9 | awk 'NR==1 {printf "%-8s %-12s %8s  %s\n", $1, $2, "RSS(MB)", $4; next} {printf "%-8s %-12s %8.1f  %s\n", $1, $2, $3/1024, $4}'
  say ""
  say "=== top 5 processes by swap usage ==="
  local f pid name swap
  for f in /proc/[0-9]*/status; do
    swap=$(awk '/^VmSwap:/ {print $2}' "${f}" 2>/dev/null || true)
    [[ -n "${swap}" && "${swap}" != "0" ]] || continue
    pid=${f#/proc/}; pid=${pid%/status}
    name=$(awk '/^Name:/ {print $2}' "${f}" 2>/dev/null || echo "?")
    printf '%s %s %s\n' "${swap}" "${pid}" "${name}"
  done | sort -rn | head -5 | awk '{printf "%-8s %-20s %6.1f MB\n", $2, $3, $1/1024}'
  say ""
  say "=== PSI memory pressure (avg10 > 10 means stalls) ==="
  cat /proc/pressure/memory 2>/dev/null || say "(PSI not available)"
}

cmd_ensure() {
  need_root
  local size=${1:-2G} want_mb have_mb=0
  want_mb=$(size_to_mb "${size}")
  if swapon --show=NAME --noheadings | grep -qx "${SWAPFILE}"; then
    have_mb=$(( $(stat -c %s "${SWAPFILE}") / 1048576 ))
    if (( have_mb >= want_mb )); then
      say "${SWAPFILE} already active (${have_mb} MB) — nothing to do"
      ensure_fstab; return
    fi
    say "resizing ${SWAPFILE}: ${have_mb} MB → ${want_mb} MB"
    swapoff "${SWAPFILE}"
    rm -f "${SWAPFILE}"
  fi
  local free_disk_mb
  free_disk_mb=$(df -Pm "$(dirname "${SWAPFILE}")" | awk 'NR==2 {print $4}')
  (( free_disk_mb > want_mb + 1024 )) || die "only ${free_disk_mb} MB disk free; need ${want_mb} MB + 1 GB headroom"

  say "creating ${SWAPFILE} (${want_mb} MB)"
  # fallocate is instant; fall back to dd on filesystems that don't support it for swap
  if ! fallocate -l "${want_mb}M" "${SWAPFILE}" 2>/dev/null; then
    dd if=/dev/zero of="${SWAPFILE}" bs=1M count="${want_mb}" status=progress
  fi
  chmod 600 "${SWAPFILE}"
  chown root:root "${SWAPFILE}"
  mkswap "${SWAPFILE}" >/dev/null
  swapon "${SWAPFILE}"
  ensure_fstab
  say "done:"; swapon --show
}

ensure_fstab() {
  if grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
    say "fstab entry present"
  else
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
    printf '%s none swap sw 0 0\n' "${SWAPFILE}" >> /etc/fstab
    say "added ${SWAPFILE} to /etc/fstab (backup saved)"
  fi
  # Validate fstab syntax so the next boot doesn't drop into emergency mode
  findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1 || warn "findmnt --verify reports issues in /etc/fstab — check it!"
}

cmd_tune() {
  need_root
  local swappiness=${1:-10}
  [[ "${swappiness}" =~ ^[0-9]+$ ]] && (( swappiness <= 200 )) || die "swappiness must be 0-200"
  cat > "${SYSCTL_FILE}" <<EOF
# Managed by swap_guard.sh
vm.swappiness = ${swappiness}
vm.vfs_cache_pressure = 50
EOF
  sysctl -p "${SYSCTL_FILE}"
}

cmd_oom_report() {
  local since=${1:-24 hours ago}
  say "=== OOM events since '${since}' ==="
  local lines
  lines=$(journalctl -k --since "${since}" --no-pager -q 2>/dev/null \
            | grep -Ei 'out of memory|oom-kill|killed process|memory cgroup out of memory' || true)
  if [[ -z "${lines}" ]]; then
    say "none 🎉"
  else
    printf '%s\n' "${lines}"
    say ""
    say "Victims (process name → count):"
    printf '%s\n' "${lines}" | grep -oE 'Killed process [0-9]+ \([^)]+\)' \
      | sed -E 's/Killed process [0-9]+ \(([^)]+)\)/\1/' | sort | uniq -c | sort -rn
  fi
  say ""
  say "=== systemd units that ended with oom-kill ==="
  systemctl list-units --type=service --all --no-legend --plain 2>/dev/null | awk '{print $1}' | while read -r u; do
    [[ "$(systemctl show -p Result --value "${u}" 2>/dev/null)" == "oom-kill" ]] && echo "  ${u}"
  done || true
  say ""
  say "Hint: exit code 137 = 128 + 9 (SIGKILL). In 'systemctl status' it shows as status=9/KILL."
}

cmd_watch() {
  local interval=30 min_avail=100 max_swap_pct=80 once=0
  while (( $# )); do
    case "$1" in
      --interval)     interval=${2:?}; shift 2 ;;
      --min-avail-mb) min_avail=${2:?}; shift 2 ;;
      --max-swap-pct) max_swap_pct=${2:?}; shift 2 ;;
      --once)         once=1; shift ;;
      *) die "unknown watch option $1" ;;
    esac
  done
  trap 'say "stopped"; exit 0' INT TERM
  while true; do
    local avail_mb swap_total swap_used_pct=0 rc=0 msg
    avail_mb=$(to_mb "$(meminfo MemAvailable)")
    swap_total=$(meminfo SwapTotal)
    (( swap_total > 0 )) && swap_used_pct=$(( (swap_total - $(meminfo SwapFree)) * 100 / swap_total ))
    msg="avail=${avail_mb}MB swap_used=${swap_used_pct}%"
    if (( avail_mb < min_avail )); then
      warn "LOW MEMORY ${msg} (< ${min_avail}MB). Top: $(ps -eo comm,rss --sort=-rss | sed -n 2p | awk '{printf "%s %dMB", $1, $2/1024}')"
      rc=1
    fi
    if (( swap_used_pct > max_swap_pct )); then
      warn "HIGH SWAP ${msg} (> ${max_swap_pct}%) — the box is thrashing; stop a service or add RAM"
      rc=1
    fi
    (( rc == 0 )) && say "$(date -u +%T) ok ${msg}"
    (( once )) && exit "${rc}"
    sleep "${interval}" & wait $!
  done
}

cmd_remove() {
  need_root
  if swapon --show=NAME --noheadings | grep -qx "${SWAPFILE}"; then swapoff "${SWAPFILE}"; fi
  rm -f "${SWAPFILE}"
  sed -i.bak "\|^${SWAPFILE}[[:space:]]|d" /etc/fstab
  say "swap removed (fstab backup: /etc/fstab.bak)"
}

main() {
  local cmd=${1:-status}; shift || true
  case "${cmd}" in
    status)      cmd_status ;;
    ensure)      cmd_ensure "$@" ;;
    tune)        cmd_tune "$@" ;;
    oom-report)  cmd_oom_report "$@" ;;
    watch)       cmd_watch "$@" ;;
    remove)      cmd_remove ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"

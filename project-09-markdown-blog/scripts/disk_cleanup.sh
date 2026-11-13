#!/usr/bin/env bash
# =============================================================================
# disk_cleanup.sh — report disk usage and safely reclaim space on a small server
# Project 09 · linux-devops-13-projects
#
#   sudo disk_cleanup.sh [--threshold PCT] [--mount /] [--dry-run] [--quiet] [--force]
#                        [--journal-size 200M] [--log-days 14] [--cache-days 7] [--keep-releases 3]
#
# Behaviour:
#   * always prints a usage report (unless --quiet and below threshold)
#   * cleans ONLY when usage of --mount ≥ --threshold (default 80 %), or with --force
#   * every step is safe: apt cache, journal vacuum, old rotated logs, stale media
#     cache, old Astro releases (never the one `current` points to), /tmp, disabled
#     snap revisions, crash dumps
#   * flock prevents overlapping cron runs
# Exit: 0 ok · 1 still ≥ threshold after cleaning (page a human) · 2 usage error
# =============================================================================
set -euo pipefail

THRESHOLD=80
MOUNT=/
DRY_RUN=0
QUIET=0
FORCE=0
JOURNAL_SIZE=200M
LOG_DAYS=14
CACHE_DAYS=7
KEEP_RELEASES=3
MEDIA_CACHE=/var/cache/mdblog/media
RELEASES_DIR=/opt/mdblog/web/releases
CURRENT_LINK=/opt/mdblog/web/current
LOCK=/run/lock/disk_cleanup.lock

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }
ts()    { date -u +%FT%TZ; }
say()   { (( QUIET )) || printf '%s %s\n' "$(ts)" "$*"; }
act()   { printf '%s   → %s\n' "$(ts)" "$*"; }
run()   { if (( DRY_RUN )); then printf '%s   [dry-run] %s\n' "$(ts)" "$*"; else "$@"; fi; }

while (( $# )); do
  case "$1" in
    --threshold)     THRESHOLD="${2:?}"; shift 2 ;;
    --mount)         MOUNT="${2:?}"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --quiet)         QUIET=1; shift ;;
    --force)         FORCE=1; shift ;;
    --journal-size)  JOURNAL_SIZE="${2:?}"; shift 2 ;;
    --log-days)      LOG_DAYS="${2:?}"; shift 2 ;;
    --cache-days)    CACHE_DAYS="${2:?}"; shift 2 ;;
    --keep-releases) KEEP_RELEASES="${2:?}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "${THRESHOLD}" =~ ^[0-9]+$ ]] && (( THRESHOLD <= 100 )) || { echo "--threshold must be 0-100" >&2; exit 2; }
[[ ${EUID} -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 2; }

exec 9>"${LOCK}"
flock -n 9 || { say "another disk_cleanup is running — exiting"; exit 0; }

used_pct()   { df -P "${MOUNT}" | awk 'NR==2 {gsub("%","",$5); print $5}'; }
avail_kb()   { df -P "${MOUNT}" | awk 'NR==2 {print $4}'; }
inode_pct()  { df -Pi "${MOUNT}" | awk 'NR==2 {gsub("%","",$5); print $5}'; }

report() {
  echo "================ disk report $(ts) ($(hostname)) ================"
  echo "--- filesystems (df -hT, real disks only)"
  df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay
  echo "--- inodes on ${MOUNT}: $(inode_pct)% used"
  echo "--- block devices (lsblk)"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null || lsblk
  echo "--- biggest directories on ${MOUNT} (du -x, depth 2)"
  du -xh --max-depth=2 "${MOUNT}" 2>/dev/null | sort -rh | head -n 12
  echo "--- files > 100 MB (same filesystem only)"
  find "${MOUNT}" -xdev -type f -size +100M -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -n 8 | awk -F'\t' '{printf "%8.1f MB  %s\n", $1/1048576, $2}'
  echo "--- deleted-but-open files (space not freed until the process restarts)"
  find /proc/[0-9]*/fd -lname '*(deleted)' -printf '%l\n' 2>/dev/null | sort | uniq -c | sort -rn | head -5 || true
  echo "--- journal: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | head -1)"
  echo "======================================================================"
}

clean_apt() {
  act "apt cache ($(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1))"
  run apt-get clean
  run apt-get -y autoremove --purge >/dev/null
}

clean_journal() {
  act "journald → vacuum to ${JOURNAL_SIZE}"
  run journalctl --vacuum-size="${JOURNAL_SIZE}" -q
}

clean_rotated_logs() {
  act "rotated logs older than ${LOG_DAYS} days in /var/log"
  # Only already-rotated files (*.gz, *.1 … *.9, -YYYYMMDD); never the live log
  local files
  files=$(find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -regex '.*-[0-9]\{8\}\(\.gz\)?' \) -mtime +"${LOG_DAYS}" -print 2>/dev/null | wc -l)
  act "  ${files} file(s)"
  (( DRY_RUN )) || find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -regex '.*-[0-9]\{8\}\(\.gz\)?' \) -mtime +"${LOG_DAYS}" -delete 2>/dev/null || true
}

clean_media_cache() {
  [[ -d "${MEDIA_CACHE}" ]] || return 0
  act "media cache: files not accessed for ${CACHE_DAYS} days in ${MEDIA_CACHE} ($(du -sh "${MEDIA_CACHE}" | cut -f1))"
  # atime under 'relatime' is updated at most daily — good enough for a cache
  if (( DRY_RUN )); then
    find "${MEDIA_CACHE}" -type f -atime +"${CACHE_DAYS}" -printf '   [dry-run] %p\n'
  else
    find "${MEDIA_CACHE}" -type f -atime +"${CACHE_DAYS}" -delete
  fi
}

clean_releases() {
  [[ -d "${RELEASES_DIR}" ]] || return 0
  local current="" r count=0
  [[ -L "${CURRENT_LINK}" ]] && current="$(readlink -f "${CURRENT_LINK}")"
  act "web releases: keep newest ${KEEP_RELEASES} + current ($(basename "${current:-none}"))"
  while IFS= read -r r; do
    count=$(( count + 1 ))
    (( count <= KEEP_RELEASES )) && continue
    [[ "$(readlink -f "${r}")" == "${current}" ]] && { act "  keep ${r} (current)"; continue; }
    act "  remove ${r}"
    run rm -rf -- "${r}"
  done < <(find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
}

clean_tmp() {
  act "/tmp and /var/tmp files older than 7 days"
  if (( ! DRY_RUN )); then
    find /tmp /var/tmp -xdev -type f -atime +7 -delete 2>/dev/null || true
  fi
}

clean_snaps() {
  command -v snap >/dev/null || return 0
  local name rev
  while read -r name rev; do
    act "snap ${name} disabled revision ${rev}"
    run snap remove "${name}" --revision="${rev}"
  done < <(LANG=C snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}')
}

clean_crash() {
  [[ -d /var/crash ]] || return 0
  act "crash dumps in /var/crash"
  if (( ! DRY_RUN )); then find /var/crash -type f -delete 2>/dev/null || true; fi
}

main() {
  local before_pct before_kb after_pct after_kb
  before_pct=$(used_pct); before_kb=$(avail_kb)

  if (( before_pct < THRESHOLD && ! FORCE )); then
    say "${MOUNT} at ${before_pct}% (< ${THRESHOLD}%) — no cleanup needed"
    (( QUIET )) || report
    exit 0
  fi

  echo "$(ts) ${MOUNT} at ${before_pct}% (threshold ${THRESHOLD}%) — cleaning$( (( DRY_RUN )) && echo ' [DRY RUN]')"
  report
  clean_apt
  clean_journal
  clean_rotated_logs
  clean_media_cache
  clean_releases
  clean_tmp
  clean_snaps
  clean_crash

  after_pct=$(used_pct); after_kb=$(avail_kb)
  echo "$(ts) done: ${before_pct}% → ${after_pct}% used, freed $(( (after_kb - before_kb) / 1024 )) MB"
  if (( after_pct >= THRESHOLD )); then
    echo "$(ts) STILL ≥ ${THRESHOLD}% — manual action needed (check the report above)" >&2
    logger -t disk_cleanup -p user.err "${MOUNT} still at ${after_pct}% after cleanup" || true
    exit 1
  fi
}

main

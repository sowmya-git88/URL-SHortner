#!/usr/bin/env bash
# =============================================================================
# log_analyzer.sh — text-pipeline analysis of SnippetBin access logs
# Project 07 · linux-devops-13-projects
#
# Log line format (written by app/app.rb PlainAccessLog):
#   2025-01-31T10:15:02Z 203.0.113.9 GET /api/snippets/Ab3dE6gH 200 12.4 512 "curl/8.5.0"
#   $1 timestamp         $2 ip       $3  $4 path               $5  $6   $7  $8.. user agent
#
# Usage:
#   log_analyzer.sh [-f FILE]... [-n TOP] [-s SINCE] [-u UNTIL] [-p PATH_REGEX]
#                   [--status REGEX] [--sections LIST] [--live]
#   -f FILE      log file(s); .gz allowed; "-" = stdin (default /var/log/snippetbin/access.log*)
#   -n TOP       rows per section (default 10)
#   -s / -u      ISO time window, prefix match works: -s 2025-01-31T10 -u 2025-01-31T12
#   -p REGEX     only paths matching REGEX (awk ERE), e.g. '^/api/snippets'
#   --status RE  only statuses matching RE, e.g. '^5' or '404'
#   --sections   comma list: summary,status,paths,ips,slow,rpm,errors,agents,scanners (default all)
#   --live       follow the log and print 4xx/5xx lines as they happen (Ctrl+C to stop)
#
# Report → stdout. Diagnostics → stderr. So:  log_analyzer.sh > report.txt 2> analyzer.err
# =============================================================================
set -euo pipefail

declare -a FILES=()
TOP=10
SINCE=""
UNTIL=""
PATH_RE=""
STATUS_RE=""
SECTIONS="summary,status,paths,ips,slow,rpm,errors,agents,scanners"
LIVE=0
DEFAULT_GLOB="/var/log/snippetbin/access.log"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }
err()   { printf 'log_analyzer: %s\n' "$*" >&2; }

while (( $# )); do
  case "$1" in
    -f) FILES+=("${2:?}"); shift 2 ;;
    -n) TOP="${2:?}"; shift 2 ;;
    -s) SINCE="${2:?}"; shift 2 ;;
    -u) UNTIL="${2:?}"; shift 2 ;;
    -p) PATH_RE="${2:?}"; shift 2 ;;
    --status)   STATUS_RE="${2:?}"; shift 2 ;;
    --sections) SECTIONS="${2:?}"; shift 2 ;;
    --live)     LIVE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) err "unknown option: $1"; usage >&2; exit 2 ;;
  esac
done
[[ "${TOP}" =~ ^[0-9]+$ ]] || { err "-n needs a number"; exit 2; }

if (( ${#FILES[@]} == 0 )); then
  shopt -s nullglob
  FILES=("${DEFAULT_GLOB}" "${DEFAULT_GLOB}".*)
  shopt -u nullglob
fi

# ---------- live mode: tail -F | grep --line-buffered ----------
if (( LIVE )); then
  target="${FILES[0]}"
  err "following ${target} (4xx/5xx only) — Ctrl+C to stop"
  # -F survives log rotation; --line-buffered stops grep from holding output in a 4 KB buffer
  tail -n0 -F "${target}" \
    | grep --line-buffered -E ' [45][0-9]{2} [0-9.]+ ' \
    | awk '{ printf "%s  %-15s %-6s %-35s %s  %sms\n", substr($1,12,8), $2, $3, $4, $5, $6; fflush() }'
  exit 0
fi

# ---------- stream all inputs (plain or gzip) to stdout ----------
emit() {
  local f
  for f in "${FILES[@]}"; do
    if [[ "${f}" == "-" ]]; then cat
    elif [[ ! -r "${f}" ]]; then err "skip unreadable ${f}"
    elif [[ "${f}" == *.gz ]]; then zcat -- "${f}"
    else cat -- "${f}"
    fi
  done
}

# ---------- filter: time window, path, status; drop malformed lines ----------
WORK="$(mktemp)"
trap 'rm -f "${WORK}"' EXIT

emit | awk -v since="${SINCE}" -v until="${UNTIL}" -v pre="${PATH_RE}" -v sre="${STATUS_RE}" '
  NF < 8 || $5 !~ /^[0-9]{3}$/ { bad++; next }
  since != "" && $1 < since     { next }
  until != "" && $1 > until "~" { next }      # "~" sorts after digits, so an hour prefix is inclusive
  pre   != "" && $4 !~ pre      { next }
  sre   != "" && $5 !~ sre      { next }
  { print }
  END { if (bad) printf "log_analyzer: ignored %d malformed lines\n", bad > "/dev/stderr" }
' > "${WORK}"

TOTAL=$(wc -l < "${WORK}")
if (( TOTAL == 0 )); then
  err "no matching log lines (files: ${FILES[*]:-none})"
  exit 1
fi

want() { [[ ",${SECTIONS}," == *",$1,"* ]]; }
hr()   { printf '\n== %s %s\n' "$1" "$(printf '%.0s=' $(seq 1 $(( 60 - ${#1} ))))"; }

# Collapse IDs so /api/snippets/Ab3dE6gH and /api/snippets/Zz9... count as one endpoint
normalize() { sed -E 's#/api/snippets/[A-Za-z0-9]{8}#/api/snippets/:id#; s#\?.*$##'; }

if want summary; then
  hr "SUMMARY"
  awk '
    { n++; ip[$2]=1; if ($5>=500) e5++; else if ($5>=400) e4++; ms+=$6
      if (first=="" || $1<first) first=$1; if ($1>last) last=$1 }
    END {
      for (i in ip) u++
      printf "requests      : %d\n", n
      printf "unique IPs    : %d\n", u
      printf "time range    : %s → %s\n", first, last
      printf "4xx           : %d (%.1f%%)\n", e4, 100*e4/n
      printf "5xx           : %d (%.1f%%)\n", e5, 100*e5/n
      printf "avg latency   : %.1f ms\n", ms/n
    }' "${WORK}"
fi

if want status; then
  hr "STATUS CODES"
  # classic pipeline: extract column → sort → count duplicates → sort by count
  awk '{print $5}' "${WORK}" | sort | uniq -c | sort -rn \
    | awk -v t="${TOTAL}" '{ bar=""; for(i=0;i<int(40*$1/t);i++) bar=bar "#"; printf "%s  %6d  %5.1f%%  %s\n", $2, $1, 100*$1/t, bar }'
fi

if want paths; then
  hr "TOP ${TOP} ENDPOINTS (method + normalized path)"
  awk '{print $3, $4}' "${WORK}" | normalize | sort | uniq -c | sort -rn | head -n "${TOP}" \
    | awk '{printf "%7d  %-6s %s\n", $1, $2, $3}'
fi

if want ips; then
  hr "TOP ${TOP} CLIENT IPs"
  cut -d' ' -f2 "${WORK}" | sort | uniq -c | sort -rn | head -n "${TOP}" | awk '{printf "%7d  %s\n", $1, $2}'
fi

if want slow; then
  hr "SLOWEST ENDPOINTS (avg / p95 / max ms, min 3 hits)"
  # sort by endpoint then latency so p95 can be picked per group in one awk pass
  awk '{print $3" "$4, $6}' "${WORK}" | normalize | sort -k1,2 -k3,3n | awk '
    function flush() {
      if (cnt >= 3) { idx=int(cnt*0.95); if (idx<1) idx=1; if (idx>cnt) idx=cnt
        printf "%-45s n=%-5d avg=%-8.1f p95=%-8.1f max=%.1f\n", key, cnt, sum/cnt, v[idx], v[cnt] }
    }
    { k=$1" "$2; if (k!=key) { flush(); key=k; cnt=0; sum=0; delete v } cnt++; v[cnt]=$3; sum+=$3 }
    END { flush() }' | sort -t= -k3 -rn | head -n "${TOP}"
fi

if want rpm; then
  hr "BUSIEST MINUTES (requests/minute)"
  # 2025-01-31T10:15:02Z → cut first 16 chars = minute bucket
  cut -c1-16 "${WORK}" | sort | uniq -c | sort -rn | head -n "${TOP}" | awk '{printf "%6d  %s\n", $1, $2}'
fi

if want errors; then
  hr "LAST ${TOP} SERVER ERRORS (5xx)"
  grep -E '^[^ ]+ [^ ]+ [A-Z]+ [^ ]+ 5[0-9]{2} ' "${WORK}" | tail -n "${TOP}" || echo "none 🎉"
fi

if want agents; then
  hr "TOP ${TOP} USER AGENTS"
  # the UA is the only double-quoted field → cut on the quote character
  cut -d'"' -f2 "${WORK}" | sed -E 's#/[0-9][0-9.]*##g' | sort | uniq -c | sort -rn | head -n "${TOP}" \
    | awk '{c=$1; $1=""; printf "%7d %s\n", c, $0}'
fi

if want scanners; then
  hr "POSSIBLE SCANNERS (IPs with ≥ 10 x 404)"
  awk '$5==404 {print $2}' "${WORK}" | sort | uniq -c | awk '$1>=10' | sort -rn | head -n "${TOP}" \
    | awk '{printf "%6d x 404  %s\n", $1, $2}' | grep . || echo "none"
fi
echo

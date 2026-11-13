#!/usr/bin/env bash
# duckdns_update.sh — point <name>.duckdns.org at this machine's current public IP.
# Reads DUCKDNS_DOMAIN and DUCKDNS_TOKEN from /etc/tickets/duckdns.env (root:root 0600).
# Cron (root):  */5 * * * * /usr/local/bin/duckdns_update.sh >/dev/null 2>&1
set -euo pipefail
ENV_FILE="${ENV_FILE:-/etc/tickets/duckdns.env}"
[[ -r "${ENV_FILE}" ]] || { echo "cannot read ${ENV_FILE}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${ENV_FILE}"
: "${DUCKDNS_DOMAIN:?set DUCKDNS_DOMAIN (without .duckdns.org)}"
: "${DUCKDNS_TOKEN:?set DUCKDNS_TOKEN}"
ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com)"
resp="$(curl -fsS --max-time 10 "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=${ip}")"
if [[ "${resp}" == "OK" ]]; then
  logger -t duckdns "updated ${DUCKDNS_DOMAIN}.duckdns.org -> ${ip}"
  echo "OK ${DUCKDNS_DOMAIN}.duckdns.org -> ${ip}"
else
  logger -t duckdns -p user.err "update failed: ${resp}"
  echo "FAILED: ${resp}" >&2
  exit 1
fi

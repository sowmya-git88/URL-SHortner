#!/usr/bin/env bash
# =============================================================================
# nginx_vhost.sh — render, validate, enable (and optionally TLS-enable) an Nginx
#                  virtual host for a PHP-FPM app, with automatic rollback
# Project 06 · linux-devops-13-projects
#
#   sudo nginx_vhost.sh create  --name tickets --domains "x.duckdns.org 1.2.3.4.sslip.io"
#                               [--web-root /opt/tickets/public] [--api-root /opt/tickets/api]
#                               [--socket /run/php/php8.3-fpm-tickets.sock]
#                               [--certbot --email you@example.com] [--staging]
#   sudo nginx_vhost.sh disable --name tickets
#   sudo nginx_vhost.sh status  --name tickets
#
# Safety: every change is validated with `nginx -t`. If validation fails, the
# previous files are restored and nginx is NOT reloaded.
# =============================================================================
set -Eeuo pipefail

ACTION="${1:-}"; shift || true
NAME=""
DOMAINS=""
WEB_ROOT=""
API_ROOT=""
FPM_SOCKET=""
WITH_CERTBOT=0
EMAIL=""
STAGING=0
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../deploy/nginx" && pwd)"
AVAILABLE=/etc/nginx/sites-available
ENABLED=/etc/nginx/sites-enabled
SNIPPETS=/etc/nginx/snippets
BACKUP_DIR=""

log()  { printf '[nginx_vhost] %s\n' "$*" >&2; }
die()  { printf '[nginx_vhost] ERROR: %s\n' "$*" >&2; exit 1; }
usage(){ sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

parse() {
  while (( $# )); do
    case "$1" in
      --name)     NAME="${2:?}"; shift 2 ;;
      --domains)  DOMAINS="${2:?}"; shift 2 ;;
      --web-root) WEB_ROOT="${2:?}"; shift 2 ;;
      --api-root) API_ROOT="${2:?}"; shift 2 ;;
      --socket)   FPM_SOCKET="${2:?}"; shift 2 ;;
      --certbot)  WITH_CERTBOT=1; shift ;;
      --email)    EMAIL="${2:?}"; shift 2 ;;
      --staging)  STAGING=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ -n "${NAME}" ]] || die "--name is required"
  [[ "${NAME}" =~ ^[a-z0-9-]+$ ]] || die "--name must be lowercase letters, digits, dashes"
  WEB_ROOT="${WEB_ROOT:-/opt/${NAME}/public}"
  API_ROOT="${API_ROOT:-/opt/${NAME}/api}"
  FPM_SOCKET="${FPM_SOCKET:-/run/php/php8.3-fpm-${NAME}.sock}"
}

backup() {
  BACKUP_DIR="$(mktemp -d /tmp/nginx_vhost.XXXXXX)"
  local f
  for f in "${AVAILABLE}/${NAME}.conf" "${SNIPPETS}/${NAME}-app.conf" "${ENABLED}/${NAME}.conf" "${ENABLED}/default"; do
    [[ -e "${f}" || -L "${f}" ]] && cp -a "${f}" "${BACKUP_DIR}/$(echo "${f}" | tr '/' '_')"
  done
  log "backup in ${BACKUP_DIR}"
}

restore() {
  log "restoring previous configuration from ${BACKUP_DIR}"
  rm -f "${AVAILABLE}/${NAME}.conf" "${SNIPPETS}/${NAME}-app.conf" "${ENABLED}/${NAME}.conf"
  local b orig
  for b in "${BACKUP_DIR}"/*; do
    [[ -e "${b}" || -L "${b}" ]] || continue
    orig="$(basename "${b}" | tr '_' '/')"
    cp -a "${b}" "${orig}"
  done
}

on_error() {
  local code=$?
  trap - ERR
  log "failed (exit ${code})"
  [[ -n "${BACKUP_DIR}" ]] && restore && nginx -t 2>/dev/null && log "previous config restored and valid"
  exit "${code}"
}
trap on_error ERR

render() {
  local tpl=$1 out=$2
  # Restrict envsubst to OUR variables, otherwise it would also replace nginx's own $uri, $host …
  SERVER_NAMES="${DOMAINS}" WEB_ROOT="${WEB_ROOT}" API_ROOT="${API_ROOT}" FPM_SOCKET="${FPM_SOCKET}" \
    envsubst '${SERVER_NAMES} ${WEB_ROOT} ${API_ROOT} ${FPM_SOCKET}' < "${tpl}" > "${out}.tmp"
  # Point the include at this app's snippet name
  sed -i "s#/etc/nginx/snippets/tickets-app.conf#${SNIPPETS}/${NAME}-app.conf#g" "${out}.tmp"
  mv "${out}.tmp" "${out}"
  chmod 0644 "${out}"
}

preflight() {
  [[ ${EUID} -eq 0 ]] || die "run with sudo"
  command -v nginx >/dev/null || die "nginx not installed (apt-get install nginx)"
  command -v envsubst >/dev/null || die "envsubst missing (apt-get install gettext-base)"
  [[ -f "${TEMPLATE_DIR}/tickets.conf.template" ]] || die "templates not found in ${TEMPLATE_DIR}"
}

check_fpm_socket() {
  if [[ -S "${FPM_SOCKET}" ]]; then
    log "PHP-FPM socket OK: $(stat -c '%A %U:%G' "${FPM_SOCKET}") ${FPM_SOCKET}"
    sudo -u www-data test -w "${FPM_SOCKET}" || die "www-data cannot write ${FPM_SOCKET} — check listen.owner/listen.mode in the pool"
  else
    log "WARNING: ${FPM_SOCKET} does not exist yet (is php8.3-fpm running with the pool?)"
  fi
}

check_web_perms() {
  [[ -d "${WEB_ROOT}" ]] || die "web root ${WEB_ROOT} missing"
  sudo -u www-data test -r "${WEB_ROOT}/index.html" || die "www-data cannot read ${WEB_ROOT}/index.html (check namei -l)"
}

cmd_create() {
  [[ -n "${DOMAINS}" ]] || die "--domains is required (space separated)"
  preflight
  check_web_perms
  check_fpm_socket
  backup
  install -d -m 0755 "${SNIPPETS}"
  render "${TEMPLATE_DIR}/tickets-app.conf.template" "${SNIPPETS}/${NAME}-app.conf"
  render "${TEMPLATE_DIR}/tickets.conf.template" "${AVAILABLE}/${NAME}.conf"
  ln -sfn "${AVAILABLE}/${NAME}.conf" "${ENABLED}/${NAME}.conf"
  # Our vhost declares default_server, so the distro default site must go
  rm -f "${ENABLED}/default"
  log "validating: nginx -t"
  nginx -t
  systemctl reload nginx
  log "vhost ${NAME} enabled for: ${DOMAINS} (+ raw IP default_server)"

  if (( WITH_CERTBOT )); then
    command -v certbot >/dev/null || die "certbot missing (apt-get install certbot python3-certbot-nginx)"
    [[ -n "${EMAIL}" ]] || die "--email is required with --certbot"
    local args=(--nginx --non-interactive --agree-tos -m "${EMAIL}" --redirect --keep-until-expiring)
    (( STAGING )) && args+=(--staging)
    local d
    for d in ${DOMAINS}; do args+=(-d "${d}"); done
    log "requesting certificate: certbot ${args[*]}"
    certbot "${args[@]}"
    nginx -t && systemctl reload nginx
    log "TLS enabled. Renewal timer: $(systemctl is-active certbot.timer 2>/dev/null || echo 'n/a')"
  fi
  rm -rf "${BACKUP_DIR}"
  cmd_status
}

cmd_disable() {
  [[ ${EUID} -eq 0 ]] || die "run with sudo"
  backup
  rm -f "${ENABLED}/${NAME}.conf"
  nginx -t
  systemctl reload nginx
  log "vhost ${NAME} disabled (file kept in ${AVAILABLE})"
}

cmd_status() {
  echo "== enabled sites =="; ls -l "${ENABLED}"
  echo "== server_name / listen in ${NAME} =="
  grep -hE '^\s*(listen|server_name|ssl_certificate )' "${AVAILABLE}/${NAME}.conf" 2>/dev/null || echo "(no file)"
  echo "== sockets =="; ss -xlp 2>/dev/null | grep -E "php.*${NAME}" || echo "(no FPM socket for ${NAME})"
  echo "== listening TCP =="; ss -tlnp | grep -E ':(80|443)\s' || true
  if command -v certbot >/dev/null; then echo "== certificates =="; certbot certificates 2>/dev/null | grep -E 'Certificate Name|Domains|Expiry' || true; fi
}

case "${ACTION}" in
  create)  parse "$@"; cmd_create ;;
  disable) parse "$@"; cmd_disable ;;
  status)  parse "$@"; cmd_status ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac

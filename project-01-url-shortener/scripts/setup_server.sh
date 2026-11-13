#!/usr/bin/env bash
# =============================================================================
# setup_server.sh — idempotent first-boot hardening for an Ubuntu 24.04 EC2 box
# Project 01 · linux-devops-13-projects
#
#   sudo bash scripts/setup_server.sh [--swap-size 2G] [--admin-user ubuntu]
#                                     [--timezone UTC] [--with-caddy] [--dry-run]
#
# What it does (each step is safe to re-run):
#   1. apt update + full-upgrade + base packages
#   2. timezone
#   3. swap file + sysctl tuning
#   4. SSH hardening via /etc/ssh/sshd_config.d drop-in (validated by sshd -t)
#   5. ufw firewall: deny inbound except 22, 80, 443
#   6. unattended security upgrades
#   7. optional: Caddy from the official apt repo + EC2_IP env drop-in
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/setup_server.log"

SWAP_SIZE="2G"
ADMIN_USER="ubuntu"
TIMEZONE="UTC"
WITH_CADDY=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} [options]
  --swap-size SIZE    swap file size (default: ${SWAP_SIZE}; use 0 to skip)
  --admin-user USER   the only user allowed to SSH in (default: ${ADMIN_USER})
  --timezone TZ       system timezone (default: ${TIMEZONE})
  --with-caddy        install Caddy and configure the EC2_IP env drop-in
  --dry-run           print what would be done without changing anything
  -h, --help          show this help
EOF
}

log()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${1}" "${2}" | tee -a "${LOG_FILE}" >&2; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
die()  { log ERROR "$*"; exit 1; }

# run: execute a command, or just print it in --dry-run mode
run() {
  if (( DRY_RUN )); then
    printf '[dry-run] %s\n' "$*" >&2
  else
    "$@"
  fi
}

on_error() {
  local exit_code=$? line=$1
  log ERROR "failed at line ${line} (exit ${exit_code}). See ${LOG_FILE}"
  exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR

parse_args() {
  while (( $# )); do
    case "$1" in
      --swap-size)  SWAP_SIZE="${2:?missing value}"; shift 2 ;;
      --admin-user) ADMIN_USER="${2:?missing value}"; shift 2 ;;
      --timezone)   TIMEZONE="${2:?missing value}"; shift 2 ;;
      --with-caddy) WITH_CADDY=1; shift ;;
      --dry-run)    DRY_RUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) usage; die "unknown option: $1" ;;
    esac
  done
}

preflight() {
  [[ ${EUID} -eq 0 ]] || die "run as root (sudo)"
  touch "${LOG_FILE}" && chmod 640 "${LOG_FILE}"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID}" == "ubuntu" ]] || die "this script targets Ubuntu (found ${ID})"
  [[ "${VERSION_ID}" == "24.04" ]] || warn "tested on 24.04, found ${VERSION_ID}"
  id "${ADMIN_USER}" &>/dev/null || die "admin user '${ADMIN_USER}' does not exist"
  local keys="/home/${ADMIN_USER}/.ssh/authorized_keys"
  [[ -s "${keys}" ]] || die "${keys} is empty — refusing to disable password login (you would lock yourself out)"
  info "preflight ok: Ubuntu ${VERSION_ID}, admin=${ADMIN_USER}, swap=${SWAP_SIZE}, caddy=${WITH_CADDY}, dry_run=${DRY_RUN}"
}

step_packages() {
  info "step 1/7: apt update + full-upgrade + base packages"
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -y
  run apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
  run apt-get install -y --no-install-recommends \
    ca-certificates curl wget git unzip jq htop tree ncdu \
    ufw unattended-upgrades apt-listchanges \
    python3 python3-venv python3-pip sqlite3 \
    gnupg debian-keyring debian-archive-keyring apt-transport-https
  run apt-get autoremove -y
}

step_timezone() {
  info "step 2/7: timezone -> ${TIMEZONE}"
  if [[ "$(timedatectl show -p Timezone --value)" != "${TIMEZONE}" ]]; then
    run timedatectl set-timezone "${TIMEZONE}"
  fi
}

step_swap() {
  info "step 3/7: swap (${SWAP_SIZE})"
  if [[ "${SWAP_SIZE}" == "0" ]]; then info "swap skipped"; return; fi
  if swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
    info "/swapfile already active"
  else
    [[ -f /swapfile ]] || run fallocate -l "${SWAP_SIZE}" /swapfile
    run chmod 600 /swapfile
    run mkswap /swapfile
    run swapon /swapfile
  fi
  if ! grep -qE '^/swapfile\s' /etc/fstab; then
    if (( DRY_RUN )); then echo "[dry-run] append /swapfile to /etc/fstab" >&2
    else echo '/swapfile none swap sw 0 0' >> /etc/fstab; fi
  fi
  if (( ! DRY_RUN )); then
    cat > /etc/sysctl.d/99-devops-lab.conf <<'EOF'
# Prefer RAM, use swap only under pressure (default is 60)
vm.swappiness = 10
# Keep dentry/inode caches a bit longer
vm.vfs_cache_pressure = 50
# Basic network hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
    sysctl --system >/dev/null
  fi
}

step_ssh() {
  info "step 4/7: SSH hardening"
  local dropin="/etc/ssh/sshd_config.d/99-hardening.conf"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<EOF
# Managed by ${SCRIPT_NAME}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowUsers ${ADMIN_USER}
EOF
  if [[ -f "${dropin}" ]] && cmp -s "${tmp}" "${dropin}"; then
    info "ssh drop-in unchanged"; rm -f "${tmp}"; return
  fi
  if (( DRY_RUN )); then cat "${tmp}" >&2; rm -f "${tmp}"; return; fi
  [[ -f "${dropin}" ]] && cp -a "${dropin}" "${dropin}.bak.$(date +%s)"
  install -m 0644 -o root -g root "${tmp}" "${dropin}"
  rm -f "${tmp}"
  # Validate BEFORE reloading: a broken sshd config + reload = locked out.
  if ! sshd -t; then
    rm -f "${dropin}"
    die "sshd -t failed; drop-in removed, sshd untouched"
  fi
  systemctl reload ssh
  info "sshd reloaded — open a SECOND terminal and test login before closing this one"
}

step_firewall() {
  info "step 5/7: ufw firewall"
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow OpenSSH          # allow SSH first so enabling cannot lock you out
  run ufw allow 80/tcp
  run ufw allow 443/tcp
  run ufw allow 443/udp
  run ufw --force enable
  (( DRY_RUN )) || ufw status verbose | tee -a "${LOG_FILE}" >&2
}

step_unattended() {
  info "step 6/7: unattended security upgrades"
  if (( ! DRY_RUN )); then
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    systemctl enable --now unattended-upgrades >/dev/null
  fi
}

step_caddy() {
  (( WITH_CADDY )) || { info "step 7/7: caddy skipped (use --with-caddy)"; return; }
  info "step 7/7: Caddy"
  if ! command -v caddy >/dev/null; then
    local keyring=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
    if (( ! DRY_RUN )); then
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o "${keyring}"
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    fi
    run apt-get update -y
    run apt-get install -y caddy
  fi
  local ip
  ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com || true)"
  [[ -n "${ip}" ]] || die "could not detect public IP"
  if (( ! DRY_RUN )); then
    echo "EC2_IP=${ip}" > /etc/caddy/caddy.env
    mkdir -p /etc/systemd/system/caddy.service.d
    printf '[Service]\nEnvironmentFile=/etc/caddy/caddy.env\n' > /etc/systemd/system/caddy.service.d/override.conf
    systemctl daemon-reload
    systemctl enable --now caddy
    systemctl restart caddy
  fi
  info "caddy ready; EC2_IP=${ip} -> https://${ip}.sslip.io"
}

summary() {
  info "==== summary ===="
  {
    echo "kernel : $(uname -r)"
    echo "memory : $(free -h | awk '/Mem:/ {print $2" total, "$7" available"}')"
    echo "swap   : $(free -h | awk '/Swap:/ {print $2}')"
    echo "disk / : $(df -h / | awk 'NR==2 {print $4" free of "$2}')"
    echo "ufw    : $(ufw status | head -1)"
    echo "reboot : $([[ -f /var/run/reboot-required ]] && echo REQUIRED || echo not required)"
  } | tee -a "${LOG_FILE}" >&2
}

main() {
  parse_args "$@"
  preflight
  step_packages
  step_timezone
  step_swap
  step_ssh
  step_firewall
  step_unattended
  step_caddy
  summary
  info "done."
}

main "$@"

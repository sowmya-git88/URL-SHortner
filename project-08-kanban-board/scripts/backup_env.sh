#!/usr/bin/env bash
# =============================================================================
# backup_env.sh — encrypted, rotated, verifiable backups of secret .env files
# Project 08 · linux-devops-13-projects
#
#   sudo backup_env.sh init-key                      # create the passphrase file (once)
#   sudo backup_env.sh backup [FILE...]              # default: /etc/kanban/kanban.env
#   sudo backup_env.sh backup --all                  # every /etc/*/*.env on the box
#   sudo backup_env.sh list
#   sudo backup_env.sh verify  BACKUP.enc
#   sudo backup_env.sh restore BACKUP.enc [--apply]  # default = dry run (shows a diff)
#   sudo backup_env.sh prune [KEEP]                  # keep newest KEEP (default 14)
#
# Crypto: tar.gz → openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -md sha256
#         passphrase read from a 0600 file (never on the command line / in `ps`)
# =============================================================================
set -Eeuo pipefail
umask 077                                  # every file we create is private by default

KEY_DIR="${KEY_DIR:-/root/.config/backup_env}"
KEY_FILE="${KEY_FILE:-${KEY_DIR}/passphrase}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/env}"
KEEP="${KEEP:-14}"
ITER=600000
CIPHER=(-aes-256-cbc -salt -pbkdf2 -iter "${ITER}" -md sha256)
DEFAULT_FILES=(/etc/kanban/kanban.env)
HOST="$(hostname -s 2>/dev/null || cat /proc/sys/kernel/hostname)"

log() { printf '%s backup_env: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

TMPDIR_CREATED=""
cleanup() { [[ -n "${TMPDIR_CREATED}" ]] && rm -rf "${TMPDIR_CREATED}"; return 0; }
trap cleanup EXIT

need_root() { [[ ${EUID} -eq 0 ]] || die "run with sudo (secrets are root-only)"; }
need_key()  {
  [[ -f "${KEY_FILE}" ]] || die "no key at ${KEY_FILE} — run: sudo $0 init-key"
  [[ "$(stat -c %a "${KEY_FILE}")" == "600" ]] || die "${KEY_FILE} must be mode 600 (is $(stat -c %a "${KEY_FILE}"))"
}

cmd_init_key() {
  need_root
  if [[ -f "${KEY_FILE}" ]]; then die "${KEY_FILE} already exists — refusing to overwrite (old backups need it!)"; fi
  install -d -m 0700 "${KEY_DIR}"
  openssl rand -base64 48 > "${KEY_FILE}"
  chmod 600 "${KEY_FILE}"
  log "created ${KEY_FILE}"
  log "IMPORTANT: copy this passphrase into your password manager. Without it the backups are useless."
}

cmd_backup() {
  need_root; need_key
  local files=()
  if [[ "${1:-}" == "--all" ]]; then
    shopt -s nullglob; files=(/etc/*/*.env); shopt -u nullglob
  elif (( $# )); then files=("$@")
  else files=("${DEFAULT_FILES[@]}")
  fi
  (( ${#files[@]} )) || die "no files to back up"
  local f
  for f in "${files[@]}"; do [[ -r "${f}" ]] || die "cannot read ${f}"; done

  install -d -m 0700 "${BACKUP_DIR}"
  local ts out
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  out="${BACKUP_DIR}/env-${HOST}-${ts}.tar.gz.enc"

  # tar keeps owner/group/mode (-p on extract) so restored files get the right permissions.
  # Paths are stored relative to / (tar -C /), e.g. etc/kanban/kanban.env
  local rel=()
  for f in "${files[@]}"; do rel+=("${f#/}"); done
  tar -C / -czf - "${rel[@]}" \
    | openssl enc "${CIPHER[@]}" -pass "file:${KEY_FILE}" -out "${out}"
  (cd "${BACKUP_DIR}" && sha256sum "$(basename "${out}")" > "$(basename "${out}").sha256")
  chmod 600 "${out}" "${out}.sha256"
  log "wrote ${out} ($(du -h "${out}" | cut -f1)) containing: ${files[*]}"
  cmd_prune "${KEEP}"
}

cmd_list() {
  need_root
  [[ -d "${BACKUP_DIR}" ]] || { log "no backups yet"; return 0; }
  find "${BACKUP_DIR}" -maxdepth 1 -name 'env-*.tar.gz.enc' -printf '%TY-%Tm-%Td %TH:%TM  %8s bytes  %p\n' | sort -r
}

decrypt_to() {   # decrypt_to BACKUP DESTDIR
  local backup=$1 dest=$2
  openssl enc -d "${CIPHER[@]}" -pass "file:${KEY_FILE}" -in "${backup}" | tar -C "${dest}" -xzpf -
}

cmd_verify() {
  need_root; need_key
  local backup=${1:?usage: verify BACKUP.enc}
  [[ -f "${backup}" ]] || die "no such file ${backup}"
  if [[ -f "${backup}.sha256" ]]; then
    (cd "$(dirname "${backup}")" && sha256sum -c --quiet "$(basename "${backup}").sha256") \
      && log "checksum OK" || die "checksum MISMATCH — file corrupted or tampered"
  else
    log "WARNING: no .sha256 sidecar"
  fi
  # A wrong passphrase or corrupted data makes openssl print "bad decrypt" and exit non-zero
  openssl enc -d "${CIPHER[@]}" -pass "file:${KEY_FILE}" -in "${backup}" | tar -tzvf - \
    || die "decryption/extraction test FAILED"
  log "decryption test OK"
}

cmd_restore() {
  need_root; need_key
  local backup=${1:?usage: restore BACKUP.enc [--apply]} apply=0
  [[ "${2:-}" == "--apply" ]] && apply=1
  cmd_verify "${backup}" >/dev/null
  TMPDIR_CREATED="$(mktemp -d)"
  decrypt_to "${backup}" "${TMPDIR_CREATED}"
  local f target
  while IFS= read -r -d '' f; do
    target="/${f#"${TMPDIR_CREATED}"/}"
    echo "── ${target}"
    if [[ -f "${target}" ]]; then
      # show which KEYS changed, never the secret values
      diff <(cut -d= -f1 "${target}" | sort) <(cut -d= -f1 "${f}" | sort) >/dev/null \
        && echo "   same keys; values $(cmp -s "${target}" "${f}" && echo identical || echo DIFFER)" \
        || { echo "   key differences (< current, > backup):"; diff <(cut -d= -f1 "${target}" | sort) <(cut -d= -f1 "${f}" | sort) | grep '^[<>]' | sed 's/^/     /' || true; }
    else
      echo "   (does not exist now — would be created)"
    fi
    if (( apply )); then
      [[ -f "${target}" ]] && cp -a "${target}" "${target}.pre-restore.$(date +%s)"
      install -D -m "$(stat -c %a "${f}")" -o "$(stat -c %u "${f}")" -g "$(stat -c %g "${f}")" "${f}" "${target}"
      echo "   restored ($(stat -c '%a %U:%G' "${target}"))"
    fi
  done < <(find "${TMPDIR_CREATED}" -type f -print0)
  (( apply )) || log "dry run only — re-run with --apply to write files"
}

cmd_prune() {
  local keep=${1:-${KEEP}}
  [[ "${keep}" =~ ^[0-9]+$ ]] || die "KEEP must be a number"
  [[ -d "${BACKUP_DIR}" ]] || return 0
  local old
  mapfile -t old < <(ls -1t "${BACKUP_DIR}"/env-*.tar.gz.enc 2>/dev/null | tail -n +"$(( keep + 1 ))")
  local f
  for f in "${old[@]}"; do
    rm -f -- "${f}" "${f}.sha256"
    log "pruned ${f}"
  done
}

main() {
  local cmd=${1:-}; shift || true
  case "${cmd}" in
    init-key) cmd_init_key ;;
    backup)   cmd_backup "$@" ;;
    list)     cmd_list ;;
    verify)   cmd_verify "$@" ;;
    restore)  cmd_restore "$@" ;;
    prune)    need_root; cmd_prune "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; exit 2 ;;
  esac
}
main "$@"

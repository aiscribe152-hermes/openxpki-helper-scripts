#!/usr/bin/env bash
set -Eeuo pipefail

APP="OpenXPKI"
REPO_RAW_BASE="${OPENXPKI_HELPER_RAW_BASE:-https://raw.githubusercontent.com/aiscribe152-hermes/openxpki-helper-scripts/main}"
INSTALL_SCRIPT_URL="${OPENXPKI_INSTALL_SCRIPT_URL:-${REPO_RAW_BASE}/install/openxpki-install.sh}"

OPENXPKI_CTID="${OPENXPKI_CTID:-}"
OPENXPKI_HOSTNAME="${OPENXPKI_HOSTNAME:-openxpki}"
OPENXPKI_CORES="${OPENXPKI_CORES:-2}"
OPENXPKI_RAM_MB="${OPENXPKI_RAM_MB:-2048}"
OPENXPKI_SWAP_MB="${OPENXPKI_SWAP_MB:-512}"
OPENXPKI_DISK_GB="${OPENXPKI_DISK_GB:-12}"
OPENXPKI_STORAGE="${OPENXPKI_STORAGE:-local-lvm}"
OPENXPKI_BRIDGE="${OPENXPKI_BRIDGE:-vmbr0}"
OPENXPKI_NET="${OPENXPKI_NET:-dhcp}"
OPENXPKI_GATEWAY="${OPENXPKI_GATEWAY:-}"
OPENXPKI_TEMPLATE_STORAGE="${OPENXPKI_TEMPLATE_STORAGE:-local}"
OPENXPKI_TEMPLATE="${OPENXPKI_TEMPLATE:-auto}"
OPENXPKI_TEMPLATE_PATTERN="${OPENXPKI_TEMPLATE_PATTERN:-debian-12-standard_.*_amd64\.tar\.(zst|gz)}"
OPENXPKI_PASSWORD="${OPENXPKI_PASSWORD:-}"
OPENXPKI_UNPRIVILEGED="${OPENXPKI_UNPRIVILEGED:-1}"
OPENXPKI_START="${OPENXPKI_START:-1}"
OPENXPKI_ADVANCED="${OPENXPKI_ADVANCED:-}"
OPENXPKI_DB_BACKEND="${OPENXPKI_DB_BACKEND:-mariadb}"
OPENXPKI_SKIP_DB="${OPENXPKI_SKIP_DB:-0}"

red=$'\033[0;31m'; green=$'\033[0;32m'; yellow=$'\033[0;33m'; blue=$'\033[0;34m'; bold=$'\033[1m'; reset=$'\033[0m'
info(){ printf '%s[INFO]%s %s\n' "$blue" "$reset" "$*"; }
ok(){ printf '%s[OK]%s %s\n' "$green" "$reset" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$yellow" "$reset" "$*"; }
fail(){ printf '%s[ERROR]%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

err_report(){
  local rc=$1 line=$2 command=$3
  fail "Command failed with exit ${rc} at line ${line}: ${command}"
}
trap 'err_report "$?" "$LINENO" "$BASH_COMMAND"' ERR

require_proxmox_host(){
  [[ $EUID -eq 0 ]] || fail "Run this script as root on a Proxmox VE host."
  need pct
  need pvesh
  need pveam
  need pvesm
  need qm
  need curl
}

is_tty(){ [[ -t 0 && -t 1 ]]; }

ask(){
  local prompt="$1" default="$2" value
  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

ask_yes_no(){
  local prompt="$1" default="${2:-y}" value suffix
  if [[ "$default" == "y" ]]; then suffix="Y/n"; else suffix="y/N"; fi
  read -r -p "${prompt} [${suffix}]: " value
  value="${value:-$default}"
  [[ "$value" =~ ^[Yy]$ ]]
}

choose_db_backend(){
  local value
  echo "Database backend:"
  echo "  1) MariaDB local server (default)"
  echo "  2) PostgreSQL local server"
  echo "  3) None / external DB later"
  read -r -p "Select database backend [1]: " value
  case "${value:-1}" in
    1) OPENXPKI_DB_BACKEND="mariadb"; OPENXPKI_SKIP_DB="0" ;;
    2) OPENXPKI_DB_BACKEND="postgresql"; OPENXPKI_SKIP_DB="0" ;;
    3) OPENXPKI_DB_BACKEND="none"; OPENXPKI_SKIP_DB="1" ;;
    *) fail "Invalid database backend selection: ${value}" ;;
  esac
}

show_detected_options(){
  echo
  echo "Detected rootdir-capable storages:"
  pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print "  - "$1" ("$2")"}' || true
  echo
  echo "Detected bridges:"
  ip -o link show type bridge 2>/dev/null | awk -F': ' '{print "  - "$2}' || true
  echo
}

advanced_settings(){
  show_detected_options
  OPENXPKI_CTID="$(ask "CTID" "${OPENXPKI_CTID:-auto}")"
  [[ "$OPENXPKI_CTID" == "auto" ]] && OPENXPKI_CTID=""
  OPENXPKI_HOSTNAME="$(ask "Hostname" "$OPENXPKI_HOSTNAME")"
  OPENXPKI_CORES="$(ask "CPU cores" "$OPENXPKI_CORES")"
  OPENXPKI_RAM_MB="$(ask "RAM MiB" "$OPENXPKI_RAM_MB")"
  OPENXPKI_SWAP_MB="$(ask "Swap MiB" "$OPENXPKI_SWAP_MB")"
  OPENXPKI_DISK_GB="$(ask "Disk GiB" "$OPENXPKI_DISK_GB")"
  OPENXPKI_STORAGE="$(ask "Container storage" "$OPENXPKI_STORAGE")"
  OPENXPKI_TEMPLATE_STORAGE="$(ask "Template storage" "$OPENXPKI_TEMPLATE_STORAGE")"
  OPENXPKI_TEMPLATE="$(ask "Template filename, or auto for latest Debian 12" "$OPENXPKI_TEMPLATE")"
  OPENXPKI_BRIDGE="$(ask "Network bridge" "$OPENXPKI_BRIDGE")"
  OPENXPKI_NET="$(ask "IPv4 CIDR or dhcp" "$OPENXPKI_NET")"
  if [[ "$OPENXPKI_NET" != "dhcp" ]]; then
    OPENXPKI_GATEWAY="$(ask "IPv4 gateway" "$OPENXPKI_GATEWAY")"
  else
    OPENXPKI_GATEWAY=""
  fi
  OPENXPKI_UNPRIVILEGED="$(ask "Unprivileged container: 1=yes, 0=no" "$OPENXPKI_UNPRIVILEGED")"
  choose_db_backend
}

print_summary(){
  echo
  echo "${bold}${APP} LXC settings${reset}"
  echo "  CTID:              ${OPENXPKI_CTID:-auto}"
  echo "  Hostname:          ${OPENXPKI_HOSTNAME}"
  echo "  Template:          ${OPENXPKI_TEMPLATE_STORAGE}:vztmpl/${OPENXPKI_TEMPLATE}"
  echo "  CPU/RAM/Swap:      ${OPENXPKI_CORES} cores / ${OPENXPKI_RAM_MB} MiB / ${OPENXPKI_SWAP_MB} MiB"
  echo "  Disk:              ${OPENXPKI_STORAGE}:${OPENXPKI_DISK_GB}G"
  echo "  Network:           ${OPENXPKI_BRIDGE}, ${OPENXPKI_NET}${OPENXPKI_GATEWAY:+, gw=${OPENXPKI_GATEWAY}}"
  echo "  Unprivileged:      ${OPENXPKI_UNPRIVILEGED}"
  echo "  DB backend:        ${OPENXPKI_DB_BACKEND}"
  echo "  OpenXPKI config:   openxpki/openxpki-config community branch"
  echo
}

configuration_menu(){
  if [[ "${OPENXPKI_ADVANCED}" == "1" ]]; then
    advanced_settings
  elif [[ "${OPENXPKI_ADVANCED}" == "0" ]]; then
    :
  elif is_tty; then
    print_summary
    if ! ask_yes_no "Use default settings?" "y"; then
      advanced_settings
    fi
  fi
  print_summary
  if is_tty; then
    ask_yes_no "Create the container now?" "y" || fail "Cancelled by operator."
  fi
}

next_ctid_fallback(){
  local id
  for id in $(seq 100 9999); do
    pct status "$id" >/dev/null 2>&1 && continue
    qm status "$id" >/dev/null 2>&1 && continue
    echo "$id"
    return 0
  done
  return 1
}

resolve_ctid(){
  local next_id
  if [[ -z "$OPENXPKI_CTID" ]]; then
    next_id="$(pvesh get /cluster/nextid 2>/dev/null || true)"
    if [[ ! "$next_id" =~ ^[0-9]+$ ]]; then
      warn "pvesh /cluster/nextid did not return a valid ID; scanning for a free ID."
      next_id="$(next_ctid_fallback)" || fail "Unable to find a free CTID."
    fi
    OPENXPKI_CTID="$next_id"
  fi
  [[ "$OPENXPKI_CTID" =~ ^[0-9]+$ ]] || fail "Invalid CTID: ${OPENXPKI_CTID}"
  if pct status "$OPENXPKI_CTID" >/dev/null 2>&1; then
    fail "Container ID ${OPENXPKI_CTID} already exists. Choose another CTID."
  fi
  if qm status "$OPENXPKI_CTID" >/dev/null 2>&1; then
    fail "VM ID ${OPENXPKI_CTID} already exists. Choose another CTID."
  fi
}

ensure_template(){
  if [[ "$OPENXPKI_TEMPLATE" == "auto" || -z "$OPENXPKI_TEMPLATE" ]]; then
    info "Resolving latest available Debian 12 LXC template"
    pveam update >/dev/null
    OPENXPKI_TEMPLATE="$(
      pveam available --section system |
        awk -v pattern="$OPENXPKI_TEMPLATE_PATTERN" '{ for (i = 1; i <= NF; i++) if ($i ~ pattern) print $i }' |
        sort -V |
        tail -n 1
    )"
    [[ -n "$OPENXPKI_TEMPLATE" ]] || fail "Could not find a Debian 12 standard amd64 template in pveam available. Run: pveam available --section system | grep debian-12"
    ok "Selected template ${OPENXPKI_TEMPLATE}"
  fi

  if ! pveam list "$OPENXPKI_TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "${OPENXPKI_TEMPLATE_STORAGE}:vztmpl/${OPENXPKI_TEMPLATE}"; then
    info "Downloading template ${OPENXPKI_TEMPLATE} to ${OPENXPKI_TEMPLATE_STORAGE}"
    pveam download "$OPENXPKI_TEMPLATE_STORAGE" "$OPENXPKI_TEMPLATE"
  fi
}

create_container(){
  local net0="name=eth0,bridge=${OPENXPKI_BRIDGE},ip=${OPENXPKI_NET}"
  [[ -n "$OPENXPKI_GATEWAY" && "$OPENXPKI_NET" != "dhcp" ]] && net0+=",gw=${OPENXPKI_GATEWAY}"

  local pw_args=()
  if [[ -n "$OPENXPKI_PASSWORD" ]]; then
    pw_args+=(--password "$OPENXPKI_PASSWORD")
  else
    warn "No OPENXPKI_PASSWORD supplied; Proxmox may prompt for a root password."
  fi

  info "Creating ${APP} container ${OPENXPKI_CTID} (${OPENXPKI_HOSTNAME})"
  pct create "$OPENXPKI_CTID" "${OPENXPKI_TEMPLATE_STORAGE}:vztmpl/${OPENXPKI_TEMPLATE}" \
    --hostname "$OPENXPKI_HOSTNAME" \
    --cores "$OPENXPKI_CORES" \
    --memory "$OPENXPKI_RAM_MB" \
    --swap "$OPENXPKI_SWAP_MB" \
    --rootfs "${OPENXPKI_STORAGE}:${OPENXPKI_DISK_GB}" \
    --net0 "$net0" \
    --unprivileged "$OPENXPKI_UNPRIVILEGED" \
    --features nesting=1 \
    --onboot 1 \
    --start "$OPENXPKI_START" \
    "${pw_args[@]}"
}

run_install(){
  [[ "$OPENXPKI_START" == "1" ]] || pct start "$OPENXPKI_CTID"
  info "Waiting for container network"
  local ready=0
  for _ in {1..60}; do
    if pct exec "$OPENXPKI_CTID" -- bash -lc 'getent hosts deb.debian.org >/dev/null 2>&1'; then
      ready=1
      break
    fi
    sleep 2
  done
  [[ "$ready" == "1" ]] || fail "Container network/DNS did not become ready. Check bridge/IP/gateway settings."

  info "Installing container bootstrap prerequisites"
  pct exec "$OPENXPKI_CTID" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends ca-certificates curl'

  info "Running OpenXPKI bootstrap inside container"
  pct exec "$OPENXPKI_CTID" -- bash -lc "export OPENXPKI_DB_BACKEND='${OPENXPKI_DB_BACKEND}' OPENXPKI_SKIP_DB='${OPENXPKI_SKIP_DB}'; curl -fsSL '${INSTALL_SCRIPT_URL}' -o /root/openxpki-install.sh && bash /root/openxpki-install.sh"
}

main(){
  require_proxmox_host
  configuration_menu
  resolve_ctid
  print_summary
  ensure_template
  create_container
  run_install
  ok "${APP} container ${OPENXPKI_CTID} created."
  echo "Next: pct enter ${OPENXPKI_CTID}"
  echo "Review /root/OPENXPKI-NEXT-STEPS.txt inside the container."
}

main "$@"

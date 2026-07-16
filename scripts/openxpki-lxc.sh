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
OPENXPKI_TEMPLATE="${OPENXPKI_TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
OPENXPKI_PASSWORD="${OPENXPKI_PASSWORD:-}"
OPENXPKI_UNPRIVILEGED="${OPENXPKI_UNPRIVILEGED:-1}"
OPENXPKI_START="${OPENXPKI_START:-1}"
OPENXPKI_ADVANCED="${OPENXPKI_ADVANCED:-0}"

red=$'\033[0;31m'; green=$'\033[0;32m'; yellow=$'\033[0;33m'; blue=$'\033[0;34m'; reset=$'\033[0m'
info(){ printf '%s[INFO]%s %s\n' "$blue" "$reset" "$*"; }
ok(){ printf '%s[OK]%s %s\n' "$green" "$reset" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$yellow" "$reset" "$*"; }
fail(){ printf '%s[ERROR]%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

trap 'fail "Failed at line $LINENO"' ERR

require_proxmox_host(){
  [[ $EUID -eq 0 ]] || fail "Run this script as root on a Proxmox VE host."
  need pct
  need pvesh
  need pveam
  need curl
}

prompt_if_advanced(){
  [[ "$OPENXPKI_ADVANCED" == "1" ]] || return 0
  read -r -p "CTID [${OPENXPKI_CTID:-auto}]: " v; OPENXPKI_CTID="${v:-$OPENXPKI_CTID}"
  read -r -p "Hostname [${OPENXPKI_HOSTNAME}]: " v; OPENXPKI_HOSTNAME="${v:-$OPENXPKI_HOSTNAME}"
  read -r -p "CPU cores [${OPENXPKI_CORES}]: " v; OPENXPKI_CORES="${v:-$OPENXPKI_CORES}"
  read -r -p "RAM MiB [${OPENXPKI_RAM_MB}]: " v; OPENXPKI_RAM_MB="${v:-$OPENXPKI_RAM_MB}"
  read -r -p "Disk GiB [${OPENXPKI_DISK_GB}]: " v; OPENXPKI_DISK_GB="${v:-$OPENXPKI_DISK_GB}"
  read -r -p "Storage [${OPENXPKI_STORAGE}]: " v; OPENXPKI_STORAGE="${v:-$OPENXPKI_STORAGE}"
  read -r -p "Bridge [${OPENXPKI_BRIDGE}]: " v; OPENXPKI_BRIDGE="${v:-$OPENXPKI_BRIDGE}"
  read -r -p "IPv4 CIDR or dhcp [${OPENXPKI_NET}]: " v; OPENXPKI_NET="${v:-$OPENXPKI_NET}"
  if [[ "$OPENXPKI_NET" != "dhcp" ]]; then
    read -r -p "Gateway [${OPENXPKI_GATEWAY}]: " v; OPENXPKI_GATEWAY="${v:-$OPENXPKI_GATEWAY}"
  fi
}

resolve_ctid(){
  if [[ -z "$OPENXPKI_CTID" ]]; then
    OPENXPKI_CTID="$(pvesh get /cluster/nextid)"
  fi
  pct status "$OPENXPKI_CTID" >/dev/null 2>&1 && fail "Container ID $OPENXPKI_CTID already exists."
}

ensure_template(){
  local template_path="/var/lib/vz/template/cache/${OPENXPKI_TEMPLATE}"
  if [[ ! -f "$template_path" ]]; then
    info "Downloading template ${OPENXPKI_TEMPLATE} to ${OPENXPKI_TEMPLATE_STORAGE}"
    pveam update >/dev/null
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
  for _ in {1..30}; do
    pct exec "$OPENXPKI_CTID" -- bash -lc 'getent hosts deb.debian.org >/dev/null 2>&1' && break
    sleep 2
  done

  info "Running OpenXPKI bootstrap inside container"
  pct exec "$OPENXPKI_CTID" -- bash -lc "curl -fsSL '${INSTALL_SCRIPT_URL}' -o /root/openxpki-install.sh && bash /root/openxpki-install.sh"
}

main(){
  require_proxmox_host
  prompt_if_advanced
  resolve_ctid
  ensure_template
  create_container
  run_install
  ok "${APP} container ${OPENXPKI_CTID} created."
  echo "Next: pct enter ${OPENXPKI_CTID}"
  echo "Review /etc/openxpki/QUICKSTART.md and docs/operator-next-steps.md in this repository."
}

main "$@"

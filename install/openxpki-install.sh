#!/usr/bin/env bash
set -Eeuo pipefail

OPENXPKI_CONFIG_REPO="${OPENXPKI_CONFIG_REPO:-https://github.com/openxpki/openxpki-config.git}"
OPENXPKI_CONFIG_BRANCH="${OPENXPKI_CONFIG_BRANCH:-community}"
OPENXPKI_PACKAGES_BASE="${OPENXPKI_PACKAGES_BASE:-https://packages.openxpki.org/v3/bookworm}"
OPENXPKI_PACKAGES_SUITE="${OPENXPKI_PACKAGES_SUITE:-bookworm}"
OPENXPKI_DB_BACKEND="${OPENXPKI_DB_BACKEND:-mariadb}"
OPENXPKI_SKIP_DB="${OPENXPKI_SKIP_DB:-0}"

red=$'\033[0;31m'; green=$'\033[0;32m'; yellow=$'\033[0;33m'; blue=$'\033[0;34m'; reset=$'\033[0m'
info(){ printf '%s[INFO]%s %s\n' "$blue" "$reset" "$*"; }
ok(){ printf '%s[OK]%s %s\n' "$green" "$reset" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$yellow" "$reset" "$*"; }
fail(){ printf '%s[ERROR]%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }
trap 'fail "Failed at line $LINENO"' ERR

require_root(){ [[ $EUID -eq 0 ]] || fail "Run inside the container as root."; }

retry_cmd(){
  local attempts="$1"
  local delay="$2"
  shift 2
  local n=1
  until "$@"; do
    if [[ "$n" -ge "$attempts" ]]; then
      return 1
    fi
    warn "Attempt ${n}/${attempts} failed: $*; retrying in ${delay}s"
    sleep "$delay"
    n=$((n + 1))
  done
}

detect_debian(){
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || fail "This installer currently supports Debian containers only."
  [[ "${VERSION_CODENAME:-}" == "bookworm" ]] || warn "Tested with Debian 12/bookworm; detected ${PRETTY_NAME:-unknown}."
}

install_base(){
  export DEBIAN_FRONTEND=noninteractive
  info "Installing base dependencies"
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg git apache2 openssl sudo
}

configure_openxpki_repo(){
  info "Configuring OpenXPKI package repository"
  install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
  curl -fsSL "${OPENXPKI_PACKAGES_BASE}/Release.key" | gpg --dearmor >/usr/share/keyrings/openxpki.pgp
  cat >/etc/apt/sources.list.d/openxpki.sources <<EOF
Types: deb
URIs: ${OPENXPKI_PACKAGES_BASE}/
Suites: ${OPENXPKI_PACKAGES_SUITE}
Components: release
Signed-By: /usr/share/keyrings/openxpki.pgp
EOF
  apt-get update
}

install_openxpki_packages(){
  local db_packages=()
  case "$OPENXPKI_DB_BACKEND" in
    mariadb) db_packages=(mariadb-server libdbd-mariadb-perl libdbd-mysql-perl) ;;
    postgres|postgresql) db_packages=(postgresql libdbd-pg-perl) ;;
    none) db_packages=() ;;
    *) fail "Unsupported OPENXPKI_DB_BACKEND=${OPENXPKI_DB_BACKEND}" ;;
  esac

  info "Installing OpenXPKI packages"
  apt-get install -y libopenxpki-perl openxpki-i18n openxpki-cgi-session-driver "${db_packages[@]}"
}

deploy_config(){
  if [[ -e /etc/openxpki && ! -d /etc/openxpki/.git ]]; then
    local backup
    backup="/etc/openxpki.backup.$(date +%Y%m%d%H%M%S)"
    warn "Existing /etc/openxpki found; moving it to ${backup}"
    mv /etc/openxpki "$backup"
  fi

  if [[ ! -d /etc/openxpki/.git ]]; then
    info "Cloning OpenXPKI community configuration"
    if ! retry_cmd 3 5 git -c http.version=HTTP/1.1 clone --depth 1 --branch "$OPENXPKI_CONFIG_BRANCH" "$OPENXPKI_CONFIG_REPO" /etc/openxpki; then
      warn "Git clone failed; falling back to GitHub branch tarball download"
      rm -rf /etc/openxpki
      mkdir -p /etc/openxpki
      retry_cmd 3 5 bash -lc "curl -fL --retry 3 --retry-delay 5 'https://codeload.github.com/openxpki/openxpki-config/tar.gz/refs/heads/${OPENXPKI_CONFIG_BRANCH}' | tar -xz --strip-components=1 -C /etc/openxpki"
    fi
  else
    info "OpenXPKI configuration already present; skipping clone"
  fi

  if [[ -d /etc/openxpki/contrib/local && ! -d /etc/openxpki/local ]]; then
    info "Creating /etc/openxpki/local from upstream template"
    cp -a /etc/openxpki/contrib/local /etc/openxpki/local
  else
    warn "No contrib/local template found or /etc/openxpki/local already exists; review local secrets manually."
  fi

  if id openxpki >/dev/null 2>&1; then
    chown -R openxpki:openxpki /etc/openxpki/config.d /etc/openxpki/local 2>/dev/null || true
  fi
  chmod -R go-rwx /etc/openxpki/local 2>/dev/null || true
}

configure_database_hint(){
  [[ "$OPENXPKI_SKIP_DB" == "1" ]] && return 0
  cat >/root/OPENXPKI-NEXT-STEPS.txt <<'EOF'
OpenXPKI package/config bootstrap is complete, but PKI initialization remains manual.

Required next steps:
1. Review /etc/openxpki/QUICKSTART.md.
2. Initialize your database using /etc/openxpki/contrib/sql for your selected backend.
3. Set /etc/openxpki/config.d/system/database.yaml.
4. Generate and protect crypto secrets under /etc/openxpki/local.
5. Start and inspect openxpki-serverd:
   systemctl start openxpki-serverd
   journalctl -u openxpki-serverd -f
6. Validate:
   oxi cli ping

Do not deploy this as production PKI until database backups, CA key backup/recovery,
realm/profile policy, and access controls are reviewed.
EOF
  warn "Database/token/realm initialization is intentionally left for operator review. See /root/OPENXPKI-NEXT-STEPS.txt"
}

enable_services(){
  systemctl enable apache2 >/dev/null 2>&1 || true
  if systemctl list-unit-files | grep -q '^openxpki-serverd\.service'; then
    systemctl enable openxpki-serverd >/dev/null 2>&1 || true
  elif systemctl list-unit-files | grep -q '^openxpkid\.service'; then
    systemctl enable openxpkid >/dev/null 2>&1 || true
  else
    warn "No OpenXPKI systemd service detected yet; inspect installed package service names."
  fi
}

main(){
  require_root
  detect_debian
  install_base
  configure_openxpki_repo
  install_openxpki_packages
  deploy_config
  configure_database_hint
  enable_services
  ok "OpenXPKI bootstrap finished. Review /root/OPENXPKI-NEXT-STEPS.txt before starting production configuration."
}

main "$@"

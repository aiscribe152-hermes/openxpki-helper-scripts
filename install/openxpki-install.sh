#!/usr/bin/env bash
set -Eeuo pipefail

OPENXPKI_HELPER_RAW_BASE="${OPENXPKI_HELPER_RAW_BASE:-https://raw.githubusercontent.com/aiscribe152-hermes/openxpki-helper-scripts/main}"
OPENXPKI_CONFIG_REPO="${OPENXPKI_CONFIG_REPO:-https://github.com/openxpki/openxpki-config.git}"
OPENXPKI_CONFIG_BRANCH="${OPENXPKI_CONFIG_BRANCH:-community}"
OPENXPKI_PACKAGES_BASE="${OPENXPKI_PACKAGES_BASE:-https://packages.openxpki.org/v3/bookworm}"
OPENXPKI_PACKAGES_SUITE="${OPENXPKI_PACKAGES_SUITE:-bookworm}"
OPENXPKI_DB_BACKEND="${OPENXPKI_DB_BACKEND:-mariadb}"
OPENXPKI_SKIP_DB="${OPENXPKI_SKIP_DB:-0}"
OPENXPKI_INIT_MODE="${OPENXPKI_INIT_MODE:-none}"

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


install_container_helper_scripts(){
  info "Installing OpenXPKI helper scripts inside container"
  install -d -m 0755 /usr/local/sbin
  retry_cmd 3 5 curl -fsSL "${OPENXPKI_HELPER_RAW_BASE}/container-scripts/openxpki-db-setup.sh" -o /usr/local/sbin/openxpki-db-setup
  retry_cmd 3 5 curl -fsSL "${OPENXPKI_HELPER_RAW_BASE}/container-scripts/openxpki-production-setup.sh" -o /usr/local/sbin/openxpki-production-setup
  chmod 0750 /usr/local/sbin/openxpki-db-setup /usr/local/sbin/openxpki-production-setup
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

write_operator_notes(){
  case "$OPENXPKI_INIT_MODE" in
    none|guided|lab) ;;
    *) warn "Unknown OPENXPKI_INIT_MODE=${OPENXPKI_INIT_MODE}; recording as none"; OPENXPKI_INIT_MODE="none" ;;
  esac

  cat >/root/OPENXPKI-NEXT-STEPS.txt <<EOF
OpenXPKI package/config bootstrap is complete.

Selected initialization mode: ${OPENXPKI_INIT_MODE}
Selected database backend: ${OPENXPKI_DB_BACKEND}
Database package install skipped: ${OPENXPKI_SKIP_DB}

What this helper already did:
- Installed OpenXPKI packages and selected database packages.
- Deployed upstream openxpki-config branch '${OPENXPKI_CONFIG_BRANCH}' to /etc/openxpki.
- Created /etc/openxpki/local from upstream templates when available.
- Enabled apache2 and the detected OpenXPKI systemd service where available.
- Installed helper scripts:
  /usr/local/sbin/openxpki-db-setup
  /usr/local/sbin/openxpki-production-setup

What still requires operator action unless you run the helper scripts below:
- Database schema initialization.
- Database user/password creation and /etc/openxpki/config.d/system/database.yaml.
- oxi CLI authentication key creation and /etc/openxpki/config.d/system/cli.yaml.
- Crypto secret values under OpenXPKI config/local files.
- Datavault token creation/import.
- Issuer CA key/certificate/token creation.
- Realm routing and profile policy review.
- Service startup and validation.

Optional in-container setup scripts:
1. Production database setup:
   /usr/local/sbin/openxpki-db-setup

2. OpenXPKI realm/secrets/CLI/issuer setup:
   /usr/local/sbin/openxpki-production-setup

Run the DB script first, then the OpenXPKI setup script.

Authoritative upstream guide:
  /etc/openxpki/QUICKSTART.md

Core validation commands after completing initialization:
  systemctl start openxpki-serverd || systemctl start openxpkid
  journalctl -u openxpki-serverd -f || journalctl -u openxpkid -f
  oxi cli ping

Security notes:
- /etc/openxpki/local and CA/token key material must be backed up securely.
- Do not commit /etc/openxpki/local secrets to Git.
- Do not deploy as production PKI until database restore, datavault restore, issuer-key recovery, realm/profile policy, and access controls have been tested.
EOF

  case "$OPENXPKI_INIT_MODE" in
    none)
      cat >>/root/OPENXPKI-NEXT-STEPS.txt <<'EOF'

Mode-specific notes: none
- The helper intentionally stopped after package/config bootstrap.
- Use this mode for production-oriented installs where secrets, realms, and CA policy are handled deliberately.
EOF
      ;;
    guided)
      cat >>/root/OPENXPKI-NEXT-STEPS.txt <<'EOF'

Mode-specific notes: guided
- Guided setup was requested.
- Helper scripts are installed for the production sequence:
  1. Run /usr/local/sbin/openxpki-db-setup to create the database/user, load schema, and write database.yaml.
  2. Run /usr/local/sbin/openxpki-production-setup to set realm config, crypto secrets, oxi CLI auth, and optionally import a software issuer CA token.
- Recommended production review sequence:
  1. Decide realm name and CA policy.
  2. Run the DB setup script and store /root/OPENXPKI-DB-CREDENTIALS.txt securely.
  3. Run the OpenXPKI setup script and store /root/OPENXPKI-PRODUCTION-SECRETS.txt securely.
  4. Prefer offline/HSM issuer keys for high-assurance production.
  5. Remove unused workflows/protocols such as EST/SCEP if not required.
  6. Start service and validate 'oxi cli ping'.
EOF
      ;;
    lab)
      cat >>/root/OPENXPKI-NEXT-STEPS.txt <<'EOF'

Mode-specific notes: lab
- Lab/demo setup was requested.
- You may run the same setup scripts for a disposable lab, but use a clearly disposable realm name and generated secrets.
- If you generate test secrets or software issuer keys, mark the CA as disposable and do not reuse it for production.
- Recommended lab sequence:
  1. Use a clearly disposable realm name such as democa or labca.
  2. Generate random DB/token/datavault secrets and save them under /root only for the lab.
  3. Create short-lived datavault and issuer CA keys.
  4. Validate the WebUI and 'oxi cli ping'.
  5. Destroy and rebuild before any production CA work.
EOF
      ;;
  esac

  cat >/root/OPENXPKI-INIT-SELECTION.txt <<EOF
OPENXPKI_INIT_MODE=${OPENXPKI_INIT_MODE}
OPENXPKI_DB_BACKEND=${OPENXPKI_DB_BACKEND}
OPENXPKI_SKIP_DB=${OPENXPKI_SKIP_DB}
EOF

  if [[ -f /etc/motd ]] && ! grep -q 'OPENXPKI-NEXT-STEPS' /etc/motd; then
    cat >>/etc/motd <<'EOF'

OpenXPKI helper notes:
  Review /root/OPENXPKI-NEXT-STEPS.txt before initializing realms, passwords, tokens, or CA keys.
EOF
  fi

  warn "OpenXPKI realm/password/token initialization still requires operator action. See /root/OPENXPKI-NEXT-STEPS.txt"
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
  install_container_helper_scripts
  write_operator_notes
  enable_services
  ok "OpenXPKI bootstrap finished. Review /root/OPENXPKI-NEXT-STEPS.txt before starting production configuration."
}

main "$@"

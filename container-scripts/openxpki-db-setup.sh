#!/usr/bin/env bash
set -Eeuo pipefail

red=$'\033[0;31m'; green=$'\033[0;32m'; yellow=$'\033[0;33m'; blue=$'\033[0;34m'; reset=$'\033[0m'
info(){ printf '%s[INFO]%s %s\n' "$blue" "$reset" "$*"; }
ok(){ printf '%s[OK]%s %s\n' "$green" "$reset" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$yellow" "$reset" "$*"; }
fail(){ printf '%s[ERROR]%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }
trap 'fail "Failed at line $LINENO: $BASH_COMMAND"' ERR

OPENXPKI_DB_BACKEND="${OPENXPKI_DB_BACKEND:-mariadb}"
OPENXPKI_DB_NAME="${OPENXPKI_DB_NAME:-openxpki}"
OPENXPKI_DB_USER="${OPENXPKI_DB_USER:-openxpki}"
OPENXPKI_DB_PASSWORD="${OPENXPKI_DB_PASSWORD:-}"
OPENXPKI_DB_HOST="${OPENXPKI_DB_HOST:-localhost}"
OPENXPKI_CONFIG_DIR="${OPENXPKI_CONFIG_DIR:-/etc/openxpki}"

require_root(){ [[ $EUID -eq 0 ]] || fail "Run as root inside the OpenXPKI container."; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }
yaml_sq(){ printf "'"; printf '%s' "$1" | sed "s/'/''/g"; printf "'"; }
sql_sq(){ printf "'"; printf '%s' "$1" | sed "s/'/''/g"; printf "'"; }
validate_db_inputs(){
  [[ "$OPENXPKI_DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || fail "DB name must contain only letters, numbers, and underscore."
  [[ "$OPENXPKI_DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || fail "DB user must contain only letters, numbers, and underscore."
}

prompt_secret(){
  local var_name="$1" prompt="$2" first second generated
  if [[ -n "${!var_name:-}" ]]; then return 0; fi
  read -r -s -p "${prompt} [leave blank to generate]: " first
  echo
  if [[ -z "$first" ]]; then
    generated="$(openssl rand -base64 33 | tr -d '\n' | tr -d '=+/ ' | cut -c1-32)"
    printf -v "$var_name" '%s' "$generated"
    warn "Generated ${var_name}; it will be recorded in /root/OPENXPKI-DB-CREDENTIALS.txt. Store it securely."
    return 0
  fi
  read -r -s -p "Confirm ${prompt}: " second
  echo
  [[ "$first" == "$second" ]] || fail "Values did not match."
  printf -v "$var_name" '%s' "$first"
}

write_credentials_file(){
  umask 077
  cat >/root/OPENXPKI-DB-CREDENTIALS.txt <<EOF
OPENXPKI_DB_BACKEND=${OPENXPKI_DB_BACKEND}
OPENXPKI_DB_HOST=${OPENXPKI_DB_HOST}
OPENXPKI_DB_NAME=${OPENXPKI_DB_NAME}
OPENXPKI_DB_USER=${OPENXPKI_DB_USER}
OPENXPKI_DB_PASSWORD=${OPENXPKI_DB_PASSWORD}
EOF
  chmod 0600 /root/OPENXPKI-DB-CREDENTIALS.txt
}

configure_database_yaml(){
  local db_type
  case "$OPENXPKI_DB_BACKEND" in
    mariadb|mysql) db_type="MariaDB2" ;;
    postgres|postgresql) db_type="PostgreSQL" ;;
    *) fail "Unsupported DB backend for database.yaml: ${OPENXPKI_DB_BACKEND}" ;;
  esac

  [[ -d "$OPENXPKI_CONFIG_DIR/config.d/system" ]] || fail "Missing ${OPENXPKI_CONFIG_DIR}/config.d/system"
  if [[ -f "$OPENXPKI_CONFIG_DIR/config.d/system/database.yaml" ]]; then
    cp -a "$OPENXPKI_CONFIG_DIR/config.d/system/database.yaml" "/root/database.yaml.backup.$(date +%Y%m%d%H%M%S)"
  fi
  cat >"$OPENXPKI_CONFIG_DIR/config.d/system/database.yaml" <<EOF
main:
    debug: 0
    type: ${db_type}
    name: $(yaml_sq "$OPENXPKI_DB_NAME")
    host: $(yaml_sq "$OPENXPKI_DB_HOST")
    user: $(yaml_sq "$OPENXPKI_DB_USER")
    passwd: $(yaml_sq "$OPENXPKI_DB_PASSWORD")
EOF
  chmod 0640 "$OPENXPKI_CONFIG_DIR/config.d/system/database.yaml"
}

setup_mariadb(){
  need mysql
  systemctl enable --now mariadb >/dev/null 2>&1 || systemctl enable --now mysql >/dev/null 2>&1 || true
  info "Creating MariaDB database/user"
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${OPENXPKI_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${OPENXPKI_DB_USER}'@'localhost' IDENTIFIED BY $(sql_sq "$OPENXPKI_DB_PASSWORD");
CREATE USER IF NOT EXISTS '${OPENXPKI_DB_USER}'@'%' IDENTIFIED BY $(sql_sq "$OPENXPKI_DB_PASSWORD");
GRANT ALL PRIVILEGES ON \`${OPENXPKI_DB_NAME}\`.* TO '${OPENXPKI_DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${OPENXPKI_DB_NAME}\`.* TO '${OPENXPKI_DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
  info "Loading OpenXPKI MariaDB schemas"
  mysql "$OPENXPKI_DB_NAME" <"$OPENXPKI_CONFIG_DIR/contrib/sql/mariadb-backend-schema.sql"
  if [[ -f "$OPENXPKI_CONFIG_DIR/contrib/sql/mariadb-frontend-schema.sql" ]]; then
    mysql "$OPENXPKI_DB_NAME" <"$OPENXPKI_CONFIG_DIR/contrib/sql/mariadb-frontend-schema.sql"
  fi
}

setup_postgresql(){
  need psql
  systemctl enable --now postgresql >/dev/null 2>&1 || true
  info "Creating PostgreSQL database/user"
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${OPENXPKI_DB_USER}'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE USER \"${OPENXPKI_DB_USER}\" WITH PASSWORD $(sql_sq "$OPENXPKI_DB_PASSWORD");"
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${OPENXPKI_DB_NAME}'" | grep -q 1; then
    sudo -u postgres createdb -O "$OPENXPKI_DB_USER" "$OPENXPKI_DB_NAME"
  fi
  info "Loading OpenXPKI PostgreSQL schemas"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$OPENXPKI_DB_NAME" -f "$OPENXPKI_CONFIG_DIR/contrib/sql/psql-backend-schema.sql"
  if [[ -f "$OPENXPKI_CONFIG_DIR/contrib/sql/psql-frontend-schema.sql" ]]; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$OPENXPKI_DB_NAME" -f "$OPENXPKI_CONFIG_DIR/contrib/sql/psql-frontend-schema.sql"
  fi
}

main(){
  require_root
  need openssl
  [[ -d "$OPENXPKI_CONFIG_DIR" ]] || fail "Missing ${OPENXPKI_CONFIG_DIR}; install OpenXPKI config first."
  validate_db_inputs
  prompt_secret OPENXPKI_DB_PASSWORD "OpenXPKI DB password"
  case "$OPENXPKI_DB_BACKEND" in
    mariadb|mysql) setup_mariadb ;;
    postgres|postgresql) setup_postgresql ;;
    *) fail "Unsupported OPENXPKI_DB_BACKEND=${OPENXPKI_DB_BACKEND}" ;;
  esac
  configure_database_yaml
  write_credentials_file
  ok "OpenXPKI production database setup complete. Credentials saved at /root/OPENXPKI-DB-CREDENTIALS.txt"
}

main "$@"

# OpenXPKI Helper Scripts

Proxmox-style helper scripts for standing up an OpenXPKI Community Edition lab container.

This repository is inspired by the Proxmox helper-script pattern at <https://community-scripts.org/> and uses the upstream OpenXPKI configuration repository at <https://github.com/openxpki/openxpki-config>.

## Status

Early bootstrap scaffold. The scripts are intended for lab/dev PKI environments first, not unattended production PKI deployment.

## What it does

- Creates a Debian 12 LXC container on a Proxmox VE host.
- Installs OpenXPKI package prerequisites from the OpenXPKI package repository.
- Installs a local database server by default, but does not initialize the OpenXPKI schema or credentials automatically.
- Installs minimal bootstrap tools (`ca-certificates` and `curl`) in the fresh container before fetching the OpenXPKI installer.
- Clones `openxpki/openxpki-config` community branch into `/etc/openxpki`.
- Retries OpenXPKI config retrieval and falls back to a GitHub branch tarball if `git clone` is interrupted.
- Prepares the local configuration directory from upstream templates when available.
- Leaves final CA/token/database realm hardening as explicit operator steps.

## Quick start

Run from a Proxmox VE host as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/aiscribe152-hermes/openxpki-helper-scripts/main/scripts/openxpki-lxc.sh)"
```

When run interactively, the helper now shows a settings summary and asks whether to use defaults or enter advanced configuration, similar to the Community Scripts flow.

Force advanced mode:

```bash
OPENXPKI_ADVANCED=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/aiscribe152-hermes/openxpki-helper-scripts/main/scripts/openxpki-lxc.sh)"
```

Force unattended default mode:

```bash
OPENXPKI_ADVANCED=0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/aiscribe152-hermes/openxpki-helper-scripts/main/scripts/openxpki-lxc.sh)"
```

## Defaults

| Setting | Default |
| --- | --- |
| CTID | next free ID from `pvesh get /cluster/nextid` |
| Hostname | `openxpki` |
| OS template | auto-resolved latest Debian 12 standard LXC template from `pveam available` |
| CPU | 2 cores |
| RAM | 2048 MiB |
| Disk | 12 GiB |
| Network | DHCP on `vmbr0` |
| DNS | Proxmox/DHCP default unless set |
| Privilege | unprivileged container |

## Configurable deployment options

Advanced mode prompts for:

- CTID or auto-selected next ID
- hostname
- CPU cores
- RAM and swap
- disk size
- container storage
- template storage
- template filename, or `auto` for the latest available Debian 12 template
- bridge
- DHCP or static IPv4/gateway
- DNS nameserver(s)
- DNS search domain
- privileged vs unprivileged container
- database backend: MariaDB, PostgreSQL, or none/external

All settings can also be supplied with environment variables, for example:

```bash
OPENXPKI_CTID=250 \
OPENXPKI_HOSTNAME=pki01 \
OPENXPKI_STORAGE=local-lvm \
OPENXPKI_BRIDGE=vmbr50 \
OPENXPKI_NET=192.168.50.250/24 \
OPENXPKI_GATEWAY=192.168.50.1 \
OPENXPKI_NAMESERVER="192.168.225.1 1.1.1.1" \
OPENXPKI_SEARCHDOMAIN=streamio.us \
OPENXPKI_DISK_GB=20 \
OPENXPKI_RAM_MB=4096 \
OPENXPKI_DB_BACKEND=mariadb \
OPENXPKI_ADVANCED=0 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/aiscribe152-hermes/openxpki-helper-scripts/main/scripts/openxpki-lxc.sh)"
```

If you want to pin a specific Proxmox template instead of auto-selecting the latest Debian 12 template:

```bash
OPENXPKI_TEMPLATE=debian-12-standard_12.12-1_amd64.tar.zst ./scripts/openxpki-lxc.sh
```

## Database handling

The installer includes a database package by default:

- `OPENXPKI_DB_BACKEND=mariadb` installs MariaDB and Perl DB drivers.
- `OPENXPKI_DB_BACKEND=postgresql` installs PostgreSQL and Perl DB drivers.
- `OPENXPKI_DB_BACKEND=none` skips local database packages.

The installer intentionally does **not** create the OpenXPKI database schema, database users, CA tokens, or production secrets. Those are PKI-sensitive operator steps documented in `/etc/openxpki/QUICKSTART.md` and `docs/operator-next-steps.md`.

## Debian 12 note

The LXC base defaults to Debian 12/bookworm to match the currently published OpenXPKI package repository. The package source remains configurable via `OPENXPKI_PACKAGES_BASE` and `OPENXPKI_PACKAGES_SUITE` for future upstream repository changes.

These can be overridden with environment variables. Example:

```bash
OPENXPKI_CTID=250 OPENXPKI_HOSTNAME=pki01 OPENXPKI_BRIDGE=vmbr50 OPENXPKI_DISK_GB=20 ./scripts/openxpki-lxc.sh
```

## Files

- `scripts/openxpki-lxc.sh` - Proxmox host-side LXC creation helper.
- `install/openxpki-install.sh` - container-side OpenXPKI bootstrap.
- `docs/operator-next-steps.md` - manual hardening/configuration tasks after bootstrap.

## Important security notes

OpenXPKI manages CA private keys and PKI secrets. Do not treat this as a production-ready one-click installer.

Before production use:

1. Replace generated/default local secrets.
2. Configure a production database backend and backup plan.
3. Protect `/etc/openxpki/local` and any CA key material.
4. Review OpenXPKI realm/profile/token settings.
5. Validate recovery of database and datavault/issuer keys.

## References

- OpenXPKI config repository: <https://github.com/openxpki/openxpki-config>
- OpenXPKI packages: <https://packages.openxpki.org/>
- Community Scripts pattern: <https://community-scripts.org/>

# OpenXPKI Helper Scripts

Proxmox-style helper scripts for standing up an OpenXPKI Community Edition lab container.

This repository is inspired by the Proxmox helper-script pattern at <https://community-scripts.org/> and uses the upstream OpenXPKI configuration repository at <https://github.com/openxpki/openxpki-config>.

## Status

Early bootstrap scaffold. The scripts are intended for lab/dev PKI environments first, not unattended production PKI deployment.

## What it does

- Creates a Debian LXC container on a Proxmox VE host.
- Installs OpenXPKI package prerequisites from the OpenXPKI package repository.
- Clones `openxpki/openxpki-config` community branch into `/etc/openxpki`.
- Prepares the local configuration directory from upstream templates when available.
- Leaves final CA/token/database realm hardening as explicit operator steps.

## Quick start

Run from a Proxmox VE host as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/aiscribe152-hermes/openxpki-helper-scripts/main/scripts/openxpki-lxc.sh)"
```

Advanced mode:

```bash
OPENXPKI_ADVANCED=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/aiscribe152-hermes/openxpki-helper-scripts/main/scripts/openxpki-lxc.sh)"
```

## Defaults

| Setting | Default |
| --- | --- |
| CTID | next free ID from `pvesh get /cluster/nextid` |
| Hostname | `openxpki` |
| OS template | Debian 12 standard LXC template |
| CPU | 2 cores |
| RAM | 2048 MiB |
| Disk | 12 GiB |
| Network | DHCP on `vmbr0` |
| Privilege | unprivileged container |

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

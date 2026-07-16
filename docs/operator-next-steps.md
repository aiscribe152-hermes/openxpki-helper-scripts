# Operator next steps

The helper script intentionally stops before irreversible PKI initialization.

## Validate install

Inside the container:

```bash
dpkg -l | grep -E 'openxpki|libopenxpki'
ls -la /etc/openxpki
systemctl status apache2 --no-pager
```

## Initialize OpenXPKI deliberately

Follow `/etc/openxpki/QUICKSTART.md` from the upstream `openxpki-config` community branch.

Key areas to complete:

1. Database schema and database connection in `config.d/system/database.yaml`.
2. CLI authentication key via `oxi cli create` and `config.d/system/cli.yaml`.
3. Crypto secrets in `config.d/system/crypto.yaml` and protected local files under `/etc/openxpki/local`.
4. Datavault token generation/import.
5. Realm/profile cleanup for your actual CA policy.
6. Apache/web UI service exposure and TLS termination.

## Production readiness checklist

- [ ] `/etc/openxpki/local` is excluded from Git and backed up securely.
- [ ] CA private keys and datavault keys have offline recovery copies.
- [ ] Database backup and restore has been tested.
- [ ] OpenXPKI service account file permissions are reviewed.
- [ ] Web UI is behind trusted TLS and access controls.
- [ ] Realm/profile templates are reviewed; unused SCEP/EST/workflows removed if not needed.
- [ ] Disaster recovery runbook exists.

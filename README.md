# 180DC ESCP Server

Ansible-managed configuration for the 180DC ESCP production server. Docker Compose remains the application runtime for Caddy, Authentik, n8n, Vexa, Whisper, and Odoo.

## Managed state

The repository manages host packages, Docker, the deployment user, SSH policy, UFW, fail2ban, swap, systemd units, Compose projects, application configuration, health verification, and backup scheduling.

Runtime state is server-local: PostgreSQL data, Docker volumes, Caddy certificates, sessions, logs, recordings, caches, and generated application files.

Caddy writes per-host JSON access logs under its persistent `/data` volume,
for example `/data/access-odoo.log` and `/data/access-login.log`. These logs
are rotated at 25 MiB, retain up to seven rolled files, and keep rolled files
for seven days. OAuth query parameters such as `code`, `state`, and
`session_state` are hashed before logging so redirect loops can be correlated
without storing raw authorization values.

## Monitoring

Run Uptime Kuma from outside this server so host/network outages are visible.
Use HTTP checks for:

- `https://login.180dc-escp.org/-/health/live/`
- `https://n8n.180dc-escp.org/`
- `https://odoo.180dc-escp.org/web/login`
- `https://vexa.180dc-escp.org/`
- `https://vexa-api.180dc-escp.org/docs`

Alert on two consecutive failures, HTTP 5xx, redirect count above eight, TLS
expiry below 14 days, and sustained response time above five seconds. Also add
a TCP check for SSH on the production host. Avoid mounting the Docker socket
into an off-box monitor; container-level state should be checked by deployment
verification and server-local diagnostics.

## Production inputs

Configure the GitHub `production` environment with these variables:

- `DEPLOY_HOST`
- `DEPLOY_PORT`
- `DEPLOY_KNOWN_HOSTS`

Configure two secrets:

- `DEPLOY_SSH_KEY`
- `PRODUCTION_SECRETS`

`PRODUCTION_SECRETS` is YAML:

```yaml
authentik:
  db_password: ""
  secret_key: ""
n8n:
  db_password: ""
  encryption_key: ""
vexa:
  db_password: ""
  admin_token: ""
odoo:
  db_password: ""
sso:
  n8n: ""
  vexa: ""
  odoo: ""
google:
  client_secret: ""
smtp:
  password: ""
```

Set the non-secret Google client ID and other platform settings in `ansible/group_vars/all.yml`.

For the first Ansible migration, copy the existing database passwords, Authentik secret key, n8n encryption key, and Vexa admin token into this bundle. Replacing those values would make existing runtime state inaccessible.

## Bootstrap

Derive the deployment public key and run the bootstrap playbook once using the server's current administrator:

```sh
export DEPLOY_HOST=server.example.org DEPLOY_PORT=22
export DEPLOY_PUBLIC_KEY="$(ssh-keygen -y -f ~/.ssh/deploy_key)"
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook ansible/bootstrap.yml \
  --private-key ~/.ssh/deploy_key -e ansible_user=root
```

After confirming that `deploy` can connect and use `sudo -n`, normal changes are applied by the GitHub workflow on pushes to `main` or by manual dispatch.

## Local development

```sh
./scripts/local.sh init
./scripts/local.sh up
./scripts/local.sh verify
./scripts/local.sh down
./scripts/local.sh reset
```

Local development exposes Authentik on port 9000, n8n on 5678, and Odoo on 8069. It does not run Caddy or Vexa.

## Backups

`180dc-backup.timer` runs daily at 03:00 UTC and retains seven backup sets per
category. It creates:

- validated PostgreSQL custom-format dumps under `/opt/180dc/backups/databases`
- validated runtime-volume archives under `/opt/180dc/backups/volumes`
- compressed Docker log snapshots under `/opt/180dc/backups/logs`

Runtime-volume backups include Caddy certificate/config volumes, n8n runtime
data, the Odoo filestore, Vexa recordings, Vexa TTS voices, and Whisper model
data.

```sh
systemctl status 180dc-backup.timer
sudo /opt/180dc/backups/backup.sh
sudo /opt/180dc/backups/restore.sh n8n n8n_YYYYMMDD_HHMMSS.dump
```

Backups are local to the production server. They protect against application
mistakes and failed deploys, but not total host loss.

# 180DC ESCP Server

Ansible-managed configuration for the 180DC ESCP production server. Docker Compose remains the application runtime for Caddy, Authentik, n8n, Vexa, Whisper, and Odoo.

## Managed state

The repository manages host packages, Docker, the deployment user, SSH policy, UFW, fail2ban, swap, systemd units, Compose projects, application configuration, health verification, and backup scheduling.

Runtime state is server-local: PostgreSQL data, Docker volumes, Caddy certificates, sessions, logs, recordings, caches, and generated application files.

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

`180dc-backup.timer` creates validated PostgreSQL custom-format dumps daily at 03:00 UTC and retains seven dumps per database:

```sh
systemctl status 180dc-backup.timer
sudo /opt/180dc/backups/backup.sh
sudo /opt/180dc/backups/restore.sh n8n n8n_YYYYMMDD_HHMMSS.dump
```

Backups are local and database-only. They do not protect Docker volumes, Odoo attachments, recordings, certificates, or the complete server from host loss.

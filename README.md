# 180DC ESCP Infra

Git-managed configuration for the 180DC ESCP homeserver.

This repository manages configuration, deployment scripts, and application-level reconciliation for exposed services. It intentionally does not manage runtime state:

- users
- sessions
- events and audit logs
- generated tokens
- application databases
- Docker volumes

Those remain server-local and are protected by database and volume backups.

## Managed services

- Caddy reverse proxy
- authentik
- n8n
- backup/restore scripts

All exposed websites and tools are expected to pass through authentik before application access.

## Deployment

Deployment is handled by GitHub Actions. The workflow copies this repo to the server, writes environment files from GitHub Actions secrets, runs a server-side backup, updates containers, reconciles authentik config, and verifies public routes.

Required GitHub Actions secrets:

- `DEPLOY_HOST`
- `DEPLOY_PORT`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `AUTHENTIK_ENV_B64`
- `N8N_ENV_B64`
- `GOOGLE_OAUTH_CLIENT_ID`
- `GOOGLE_OAUTH_CLIENT_SECRET`

## Authentik

`authentik/apply-config.py` is the current source of truth for authentik app config. It reconciles:

- Google OAuth source
- Google-only login identification
- internal-user enrollment for Google users
- `@180dc.org` allow policy
- proxy applications/providers for n8n, hooks, BIMI, and retired Odoo
- embedded outpost host/browser settings

Auth flows, users, sessions, generated tokens, and audit/event state remain in the authentik database.

## n8n

n8n is protected by authentik at the reverse proxy. Native OIDC/SAML inside n8n should be configured only with a valid n8n plan/license that supports those features.

## Manual deploy from server

```sh
cd /opt/180dc-git/current
./scripts/deploy.sh
```


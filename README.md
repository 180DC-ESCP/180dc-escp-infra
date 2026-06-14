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
- Vexa Lite
- Odoo
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
- `VEXA_ENV_B64`
- `ODOO_ENV_B64`
- `GOOGLE_OAUTH_CLIENT_ID`
- `GOOGLE_OAUTH_CLIENT_SECRET`

Create each `*_ENV_B64` secret from a production env file with the same keys as the matching `.env.example` file:

```sh
base64 < vexa/.env.production | gh secret set VEXA_ENV_B64 --body-file -
base64 < odoo/.env.production | gh secret set ODOO_ENV_B64 --body-file -
```

## Authentik

`authentik/apply-config.py` is the current source of truth for authentik app config. It reconciles:

- Google OAuth source
- Google-only login identification
- internal-user enrollment for Google users
- `@180dc.org` allow policy
- proxy applications/providers for n8n, hooks, BIMI, Vexa, and Odoo
- embedded outpost host/browser settings

Auth flows, users, sessions, generated tokens, and audit/event state remain in the authentik database.

## n8n

n8n uses a custom Authentik SSO external hook mounted from `n8n/authentik-sso-hook.js`. Authentik authenticates the Google user at the proxy, Caddy forwards verified identity headers, and the hook provisions/signs an n8n session. The n8n image is pinned by `N8N_IMAGE_TAG`; update it deliberately and verify the hook because it depends on n8n's internal JWT/user APIs.

## Vexa

Vexa Lite dashboard is protected by authentik at `https://vexa.180dc-escp.org` and is visible to all allowed `@180dc.org` Google users. The `vexa/sso-bridge.py` service turns the verified Authentik identity headers into a Vexa user and dashboard session token. The API gateway is available at `https://vexa-api.180dc-escp.org` and internally at `http://vexa-lite:8056` from the shared Docker proxy network.

Vexa API access is still controlled with Vexa API tokens. Public Admin API paths under `https://vexa-api.180dc-escp.org/admin/*` are protected by authentik.

The Odoo CSV files are one-time migration inputs and are not used by the deployment pipeline.

`escp@180dc.org` is the platform admin target. Existing default/admin owner accounts in authentik, n8n, and Odoo live in their application databases; remove or demote them during live migration after confirming `escp@180dc.org` can sign in and administer the app.

## Odoo

Odoo is deployed as a managed app at `https://odoo.180dc-escp.org` and protected by authentik at the reverse proxy. Normal deploys start the existing Odoo database without reinstalling modules or rerunning CSV imports.

Initial production setup is explicit and one-time:

```sh
cd /opt/180dc-git/current
./scripts/deploy.sh
./scripts/init-odoo.sh
```

The `init` profile installs `student_society` into the `student_society` database, runs the addon post-init hook, and imports the CSV files mounted from the Odoo app folder. After initialization, future deploys only start `odoo`.

Native Authentik/Odoo SSO should be configured through Odoo's OAuth Authentication settings or a managed Odoo auth addon after the database exists and `escp@180dc.org` is the administrator.

## Manual deploy from server

```sh
cd /opt/180dc-git/current
./scripts/deploy.sh
```

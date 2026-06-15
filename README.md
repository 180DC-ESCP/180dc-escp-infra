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

Deploys are idempotent. `docker compose up -d` is run for each managed Compose project, so Docker only recreates containers when the service definition or image actually changes. Bind-mounted config that Compose cannot detect is handled with service-level reloads, for example Caddy receives `caddy reload` after its config is synced.

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

Create each `*_ENV_B64` secret from a production env file with the same keys as the matching `.env.example` file, except `SSO_SHARED_SECRET`; deploy generates that automatically and injects it into every bridge service.

```sh
base64 < vexa/.env.production | gh secret set VEXA_ENV_B64 --body-file -
base64 < odoo/.env.production | gh secret set ODOO_ENV_B64 --body-file -
```

## Local Stack Run

Use `scripts/local.sh` to run the core service topology locally with Docker Compose: Authentik, n8n, Odoo, and Caddy. Vexa and its local Whisper transcription container are intentionally excluded from local runs because the production stack uses large speech images that are not needed for Mac smoke testing.

This is not a separate test fixture: it uses the real Compose files, generated local overrides under `.local/`, local `.env` files, and the same public hostnames mapped to `127.0.0.1`.

Add local DNS entries:

```sh
sudo sh -c 'printf "\n127.0.0.1 login.180dc-escp.org n8n.180dc-escp.org hooks.180dc-escp.org odoo.180dc-escp.org\n" >> /etc/hosts'
```

Create local env files:

```sh
./scripts/local.sh init
```

Then set real Google OAuth credentials in `authentik/.env`:

```txt
GOOGLE_OAUTH_CLIENT_ID=...
GOOGLE_OAUTH_CLIENT_SECRET=...
```

The Google OAuth redirect URI for local and prod is:

```txt
https://login.180dc-escp.org/source/oauth/callback/google/
```

Start the local stack:

```sh
./scripts/local.sh up
```

Useful commands:

```sh
./scripts/local.sh verify
./scripts/local.sh status
./scripts/local.sh logs
./scripts/local.sh down
./scripts/local.sh reset
```

`down` keeps Docker volumes. `reset` deletes local volumes and generated `.local/` files. Caddy uses local TLS certificates, so browsers may show a certificate warning unless you trust Caddy's local CA. Use a separate browser profile so local cookies do not mix with production cookies.

Ignored local migration CSVs can be placed at the repository root for Odoo initialization:

```txt
Member Database - Member Database.csv
Client Database - Project Database.csv
Client Database - Client Database.csv
```

The CSVs are mounted only into the local Odoo init container. They remain ignored and must not be committed.

## Authentik

`authentik/apply-config.py` is the current source of truth for authentik app config. It reconciles:

- Google OAuth source
- Google-only login identification
- internal-user enrollment for Google users
- `@180dc.org` allow policy
- proxy applications/providers for n8n, hooks, Vexa, and Odoo
- embedded outpost host/browser settings

Auth flows, users, sessions, generated tokens, and audit/event state remain in the authentik database.

## n8n

n8n uses a custom Authentik SSO external hook mounted from `n8n/authentik-sso-hook.js`. Authentik authenticates the Google user at the proxy, Caddy forwards verified identity headers plus the internal SSO bridge secret, and the hook reconciles the n8n user before signing an n8n session. The n8n image is pinned by `N8N_IMAGE_TAG`; update it deliberately and verify the hook because it depends on n8n's internal JWT/user APIs.

## Vexa

Vexa Lite dashboard is protected by authentik at `https://vexa.180dc-escp.org` and is visible to all allowed `@180dc.org` Google users. The `vexa/sso-bridge.py` service verifies the internal SSO bridge secret, turns the verified Authentik identity headers into a reconciled Vexa user, and creates a dashboard session token. The API gateway is available at `https://vexa-api.180dc-escp.org` and internally at `http://vexa-lite:8056` from the shared Docker proxy network.

Transcription is local. Vexa Lite points at the private `whisper` service in `vexa/docker-compose.yml`, which runs Whisper `base` through an OpenAI-compatible `/v1/audio/transcriptions` endpoint on the internal Vexa network. The Whisper service is not exposed through Caddy.

Vexa API access is still controlled with Vexa API tokens. Public Admin API paths under `https://vexa-api.180dc-escp.org/admin/*` are protected by authentik.

The Odoo migration CSVs were production migration inputs. They are not part of the managed repo or deploy path.

`escp@180dc.org` is the platform admin target. Existing default/admin owner accounts in authentik, n8n, and Odoo live in their application databases; remove or demote them during live migration after confirming `escp@180dc.org` can sign in and administer the app.

## Odoo

Odoo is deployed as a managed app at `https://odoo.180dc-escp.org` and protected by authentik at the reverse proxy. Normal deploys start the existing Odoo database without reinstalling modules or rerunning CSV imports.
Odoo migration data lives only in the initialized production database and its backups. Do not recommit member/client migration exports to this repository.

Odoo uses `student_society.controllers.authentik_sso` for Authentik SSO. Caddy redirects `/login`, `/signin`, and `/web/login` to `/auth/authentik/login`; the controller verifies the internal SSO bridge secret, consumes verified Authentik identity headers, reconciles an internal Odoo user, assigns member/admin groups, and finalizes the Odoo session.

Initial production setup is automatic during deploy:

```sh
cd /opt/180dc-git/current
./scripts/deploy.sh
```

The `init` profile installs `student_society` into the `student_society` database when the database has no Odoo schema yet. After initialization, future deploys only start the existing `odoo` service.

## Manual deploy from server

```sh
cd /opt/180dc-git/current
./scripts/deploy.sh
```

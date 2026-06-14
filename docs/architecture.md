# Architecture

## Git-managed

- Docker Compose definitions
- Caddy routing and forward-auth enforcement
- Authentik Google login and proxy app configuration
- backup/restore scripts
- deployment automation
- app secrets stored as GitHub Actions secrets

## Server-managed

- users
- sessions
- events and audit logs
- generated tokens
- PostgreSQL runtime state
- Docker volumes
- local backup archives

## Authentication rule

All public services must be routed through Caddy and protected with the Authentik forward-auth snippet unless the endpoint is intentionally public.

The Vexa API gateway is intentionally exposed at `vexa-api.180dc-escp.org` for API-key based clients. Its `/admin/*` paths remain behind Authentik.

Unsupported app-native SSO is handled with explicit adapters:

- n8n: `n8n/authentik-sso-hook.js` is mounted through n8n's external hooks system and creates n8n sessions from Authentik identity headers.
- Vexa: `vexa/sso-bridge.py` receives Authentik identity headers, provisions a Vexa user through the Admin API, creates a scoped Vexa token, and sets the dashboard cookies.

These adapters are part of the managed configuration and should be verified before app image upgrades.

Currently managed public hosts:

- `login.180dc-escp.org`
- `n8n.180dc-escp.org`
- `hooks.180dc-escp.org`
- `bimi.180dc-escp.org`
- `vexa.180dc-escp.org`
- `vexa-api.180dc-escp.org`
- `odoo.180dc-escp.org`

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

Currently managed public hosts:

- `login.180dc-escp.org`
- `n8n.180dc-escp.org`
- `hooks.180dc-escp.org`
- `bimi.180dc-escp.org`
- `odoo.180dc-escp.org` returns `410 Gone` after Authentik


# Backups

Backups are server-local runtime state. They are not committed to Git.

The deployment script runs `/opt/180dc/backups/backup.sh` before applying config if that script already exists on the server.

The backup scope should include:

- authentik PostgreSQL database
- n8n PostgreSQL database
- Vexa PostgreSQL database
- Odoo PostgreSQL database
- Caddy data/config volumes
- n8n data volume
- Vexa recordings and TTS voice cache volumes
- Odoo filestore volume
- authentik local data directory

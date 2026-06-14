#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/180dc/backups"

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <component> <backup-file>"
  echo ""
  echo "Components:"
  echo "  authentik-db    - Restore authentik database"
  echo "  n8n-db          - Restore n8n database"
  echo "  vexa-db         - Restore Vexa database"
  echo "  odoo-db         - Restore Odoo database"
  echo "  caddy           - Restore Caddy data volume"
  echo "  n8n-data        - Restore n8n data volume"
  echo "  vexa-recordings - Restore Vexa recordings volume"
  echo "  vexa-tts-voices - Restore Vexa TTS voices volume"
  echo "  odoo-web-data   - Restore Odoo filestore volume"
  echo "  authentik-data  - Restore authentik data directory"
  exit 1
fi

COMPONENT="$1"
BACKUP_FILE="$BACKUP_DIR/$2"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Error: Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

echo "=== Restoring $COMPONENT from $BACKUP_FILE ==="
echo "WARNING: This will overwrite current data!"
read -r -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Restore cancelled."
  exit 0
fi

case "$COMPONENT" in
  authentik-db)
    echo "Stopping authentik services..."
    docker compose -f /opt/180dc/authentik/docker-compose.yml stop server worker
    echo "Restoring database..."
    gunzip -c "$BACKUP_FILE" | docker exec -i authentik-db psql -U authentik -d authentik
    echo "Starting authentik services..."
    docker compose -f /opt/180dc/authentik/docker-compose.yml start server worker
    ;;
  n8n-db)
    echo "Stopping n8n..."
    docker compose -f /opt/180dc/apps/n8n/docker-compose.yml stop n8n
    echo "Restoring database..."
    gunzip -c "$BACKUP_FILE" | docker exec -i n8n-db psql -U n8n -d n8n
    echo "Starting n8n..."
    docker compose -f /opt/180dc/apps/n8n/docker-compose.yml start n8n
    ;;
  vexa-db)
    echo "Stopping Vexa..."
    docker compose -f /opt/180dc/apps/vexa/docker-compose.yml stop vexa-lite
    echo "Restoring database..."
    gunzip -c "$BACKUP_FILE" | docker exec -i vexa-db psql -U vexa -d vexa
    echo "Starting Vexa..."
    docker compose -f /opt/180dc/apps/vexa/docker-compose.yml start vexa-lite
    ;;
  odoo-db)
    echo "Stopping Odoo..."
    docker compose -f /opt/180dc/apps/odoo/docker-compose.yml stop odoo
    echo "Restoring database..."
    gunzip -c "$BACKUP_FILE" | docker exec -i odoo-db psql -U odoo -d student_society
    echo "Starting Odoo..."
    docker compose -f /opt/180dc/apps/odoo/docker-compose.yml start odoo
    ;;
  caddy)
    echo "Stopping Caddy..."
    docker compose -f /opt/180dc/caddy/docker-compose.yml stop
    echo "Restoring volume..."
    docker run --rm -v caddy_caddy_data:/data -v "$BACKUP_DIR":/backup alpine sh -c "cd /data && rm -rf ./* && tar xzf /backup/$(basename "$BACKUP_FILE")"
    echo "Starting Caddy..."
    docker compose -f /opt/180dc/caddy/docker-compose.yml start
    ;;
  n8n-data)
    echo "Stopping n8n..."
    docker compose -f /opt/180dc/apps/n8n/docker-compose.yml stop n8n
    echo "Restoring volume..."
    docker run --rm -v n8n_n8n_data:/data -v "$BACKUP_DIR":/backup alpine sh -c "cd /data && rm -rf ./* && tar xzf /backup/$(basename "$BACKUP_FILE")"
    echo "Starting n8n..."
    docker compose -f /opt/180dc/apps/n8n/docker-compose.yml start n8n
    ;;
  vexa-recordings)
    echo "Stopping Vexa..."
    docker compose -f /opt/180dc/apps/vexa/docker-compose.yml stop vexa-lite
    echo "Restoring volume..."
    docker run --rm -v vexa_recordings:/data -v "$BACKUP_DIR":/backup alpine sh -c "cd /data && rm -rf ./* && tar xzf /backup/$(basename "$BACKUP_FILE")"
    echo "Starting Vexa..."
    docker compose -f /opt/180dc/apps/vexa/docker-compose.yml start vexa-lite
    ;;
  vexa-tts-voices)
    echo "Stopping Vexa..."
    docker compose -f /opt/180dc/apps/vexa/docker-compose.yml stop vexa-lite
    echo "Restoring volume..."
    docker run --rm -v vexa_tts_voices:/data -v "$BACKUP_DIR":/backup alpine sh -c "cd /data && rm -rf ./* && tar xzf /backup/$(basename "$BACKUP_FILE")"
    echo "Starting Vexa..."
    docker compose -f /opt/180dc/apps/vexa/docker-compose.yml start vexa-lite
    ;;
  odoo-web-data)
    echo "Stopping Odoo..."
    docker compose -f /opt/180dc/apps/odoo/docker-compose.yml stop odoo
    echo "Restoring volume..."
    docker run --rm -v odoo_odoo-web-data:/data -v "$BACKUP_DIR":/backup alpine sh -c "cd /data && rm -rf ./* && tar xzf /backup/$(basename "$BACKUP_FILE")"
    echo "Starting Odoo..."
    docker compose -f /opt/180dc/apps/odoo/docker-compose.yml start odoo
    ;;
  authentik-data)
    echo "Stopping authentik services..."
    docker compose -f /opt/180dc/authentik/docker-compose.yml stop server worker
    echo "Restoring data directory..."
    find /opt/180dc/authentik/data -mindepth 1 -delete
    tar xzf "$BACKUP_FILE" -C /opt/180dc/authentik/data
    echo "Starting authentik services..."
    docker compose -f /opt/180dc/authentik/docker-compose.yml start server worker
    ;;
  *)
    echo "Error: Unknown component: $COMPONENT" >&2
    exit 1
    ;;
esac

echo "=== Restore completed ==="

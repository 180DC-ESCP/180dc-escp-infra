#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/180dc/backups/databases"

usage() {
  echo "Usage: $0 <authentik|n8n|vexa|odoo> <backup-file>"
  echo "Backup files are read from $BACKUP_DIR."
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 1
fi

COMPONENT="$1"
BACKUP_NAME="$2"

if [ "$(basename "$BACKUP_NAME")" != "$BACKUP_NAME" ]; then
  echo "Backup file must be a filename inside $BACKUP_DIR" >&2
  exit 1
fi

BACKUP_FILE="$BACKUP_DIR/$BACKUP_NAME"
if [ ! -f "$BACKUP_FILE" ]; then
  echo "Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

case "$COMPONENT" in
  authentik)
    CONTAINER="authentik-db"; DB_USER="authentik"; DB_NAME="authentik"
    COMPOSE_FILE="/opt/180dc/authentik/docker-compose.yml"; SERVICES=(server worker)
    ;;
  n8n)
    CONTAINER="n8n-db"; DB_USER="n8n"; DB_NAME="n8n"
    COMPOSE_FILE="/opt/180dc/apps/n8n/docker-compose.yml"; SERVICES=(n8n)
    ;;
  vexa)
    CONTAINER="vexa-db"; DB_USER="vexa"; DB_NAME="vexa"
    COMPOSE_FILE="/opt/180dc/apps/vexa/docker-compose.yml"; SERVICES=(vexa-lite vexa-sso)
    ;;
  odoo)
    CONTAINER="odoo-db"; DB_USER="odoo"; DB_NAME="student_society"
    COMPOSE_FILE="/opt/180dc/apps/odoo/docker-compose.yml"; SERVICES=(odoo)
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

case "$BACKUP_NAME" in
  "${COMPONENT}_"*.dump|"${COMPONENT}_"*.sql.gz) ;;
  *)
    echo "Backup filename does not match component $COMPONENT: $BACKUP_NAME" >&2
    exit 1
    ;;
esac

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != "true" ]; then
  echo "Database container is not running: $CONTAINER" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d%H%M%S)_$$"
STAGING_DB="${DB_NAME}_restore_${STAMP}"
PREVIOUS_DB="${DB_NAME}_previous_${STAMP}"
SERVICES_STOPPED=false
SWAP_STARTED=false

database_exists() {
  local name="$1"
  docker exec "$CONTAINER" psql -XAt -U "$DB_USER" -d postgres \
    -c "SELECT 1 FROM pg_database WHERE datname = '$name'" \
    | grep -qx 1
}

drop_database() {
  local name="$1"
  docker exec "$CONTAINER" dropdb --if-exists --force -U "$DB_USER" "$name"
}

cleanup() {
  local status="$?"
  trap - EXIT

  if [ "$status" -ne 0 ]; then
    echo "Restore failed; cleaning up staging database" >&2
    if [ "$SWAP_STARTED" = true ] && ! database_exists "$DB_NAME" && database_exists "$PREVIOUS_DB"; then
      docker exec "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
        -c "ALTER DATABASE \"$PREVIOUS_DB\" RENAME TO \"$DB_NAME\"" || true
    fi
    drop_database "$STAGING_DB" >/dev/null 2>&1 || true
  fi

  if [ "$SERVICES_STOPPED" = true ]; then
    docker compose -f "$COMPOSE_FILE" start "${SERVICES[@]}" || true
  fi
  exit "$status"
}
trap cleanup EXIT

echo "=== Restoring $COMPONENT from $BACKUP_FILE ==="
echo "The current database remains untouched until the backup imports successfully."
read -r -p "Type 'yes' to continue: " confirm
if [ "$confirm" != "yes" ]; then
  echo "Restore cancelled."
  exit 0
fi

drop_database "$STAGING_DB" >/dev/null
docker exec "$CONTAINER" createdb -U "$DB_USER" -O "$DB_USER" "$STAGING_DB"

case "$BACKUP_FILE" in
  *.dump)
    docker exec -i "$CONTAINER" pg_restore \
      --exit-on-error --no-owner --role "$DB_USER" \
      -U "$DB_USER" -d "$STAGING_DB" < "$BACKUP_FILE"
    ;;
  *.sql.gz)
    gzip -dc "$BACKUP_FILE" | docker exec -i "$CONTAINER" \
      psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$STAGING_DB"
    ;;
  *)
    echo "Unsupported backup format; expected .dump or .sql.gz" >&2
    exit 1
    ;;
esac

docker exec "$CONTAINER" psql -XAt -U "$DB_USER" -d "$STAGING_DB" -c "SELECT 1" | grep -qx 1

docker compose -f "$COMPOSE_FILE" stop "${SERVICES[@]}"
SERVICES_STOPPED=true

docker exec "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid()" >/dev/null

SWAP_STARTED=true
docker exec "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
  -c "ALTER DATABASE \"$DB_NAME\" RENAME TO \"$PREVIOUS_DB\""
docker exec "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
  -c "ALTER DATABASE \"$STAGING_DB\" RENAME TO \"$DB_NAME\""
drop_database "$PREVIOUS_DB"
SWAP_STARTED=false

docker compose -f "$COMPOSE_FILE" start "${SERVICES[@]}"
SERVICES_STOPPED=false
echo "=== Restore completed successfully ==="

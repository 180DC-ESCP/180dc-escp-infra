#!/usr/bin/env bash
set -euo pipefail

umask 077

exec 9>/run/lock/180dc-backup.lock
if ! flock -n 9; then
  echo "Another backup is already running" >&2
  exit 1
fi

BACKUP_DIR="/opt/180dc/backups/databases"
BACKUP_CONFIG_FILE="${BACKUP_CONFIG_FILE:-/opt/180dc/backups/database.env}"
DATE="$(date +%Y%m%d_%H%M%S)"
RETENTION_COUNT="${RETENTION_COUNT:-7}"

if [ -f "$BACKUP_CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$BACKUP_CONFIG_FILE"
fi

if ! [[ "$RETENTION_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "RETENTION_COUNT must be a positive integer" >&2
  exit 1
fi

echo "=== Starting database backup at $(date) ==="
install -d -m 700 "$BACKUP_DIR"

backup_postgres() {
  local container="$1"
  local user="$2"
  local db="$3"
  local name="$4"
  local target="$BACKUP_DIR/${name}_${DATE}.dump"
  local temporary="${target}.tmp"

  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]; then
    echo "Cannot back up $name: container $container is not running" >&2
    return 1
  fi

  echo "Backing up $name database..."
  rm -f "$temporary"
  if ! nice -n 10 ionice -c 2 -n 7 docker exec "$container" pg_dump \
    --username "$user" \
    --format custom \
    --compress 6 \
    --no-owner \
    "$db" > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi

  if ! nice -n 10 ionice -c 2 -n 7 docker exec -i "$container" pg_restore --list < "$temporary" >/dev/null; then
    echo "Backup validation failed for $name" >&2
    rm -f "$temporary"
    return 1
  fi

  mv "$temporary" "$target"

  mapfile -t expired < <(
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "${name}_*.dump" -printf '%f\n' \
      | sort -r \
      | tail -n "+$((RETENTION_COUNT + 1))"
  )
  if [ "${#expired[@]}" -gt 0 ]; then
    printf '%s\0' "${expired[@]}" | xargs -0 -r -I{} rm -f -- "$BACKUP_DIR/{}"
  fi
}

backup_postgres authentik-db "${AUTHENTIK_DB_USER:-authentik}" "${AUTHENTIK_DB_NAME:-authentik}" authentik
backup_postgres n8n-db "${N8N_DB_USER:-n8n}" "${N8N_DB_NAME:-n8n}" n8n
backup_postgres vexa-db "${VEXA_DB_USER:-vexa}" "${VEXA_DB_NAME:-vexa}" vexa
backup_postgres odoo-db "${ODOO_DB_USER:-odoo}" "${ODOO_DB_NAME:-student_society}" odoo

# Runtime volumes are intentionally not backed up. Remove archives created by
# older versions of this script so deployment frequency cannot consume the disk.
rm -rf /opt/180dc/backups/volumes
# Custom-format dumps supersede legacy compressed SQL snapshots.
find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.sql.gz' -delete

echo "=== Database backup completed at $(date) ==="
du -sh /opt/180dc/backups
find "$BACKUP_DIR" -maxdepth 1 -type f -name "*_${DATE}.dump" -printf '%f %k KiB\n' | sort

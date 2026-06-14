#!/usr/bin/env bash
set -euo pipefail

umask 077

BACKUP_DIR="/opt/180dc/backups"
DATE="$(date +%Y%m%d_%H%M%S)"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

echo "=== Starting backup at $(date) ==="

mkdir -p "$BACKUP_DIR/databases" "$BACKUP_DIR/volumes"

backup_postgres() {
  local container="$1"
  local user="$2"
  local db="$3"
  local name="$4"
  local target="$BACKUP_DIR/databases/${name}_${DATE}.sql.gz"

  if ! docker container inspect "$container" >/dev/null 2>&1; then
    echo "Skipping $name database: container $container does not exist."
    return
  fi

  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
    echo "Skipping $name database: container $container is not running."
    return
  fi

  echo "Backing up $name database..."
  docker exec "$container" pg_dump -U "$user" "$db" | gzip > "$target"
}

backup_volume() {
  local volume="$1"
  local name="$2"
  local target="/backup/${name}_${DATE}.tar.gz"

  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "Skipping $name volume: Docker volume $volume does not exist."
    return
  fi

  echo "Backing up $name volume..."
  docker run --rm -v "$volume":/data:ro -v "$BACKUP_DIR/volumes":/backup alpine tar czf "$target" -C /data .
}

backup_directory() {
  local source="$1"
  local name="$2"
  local target="$BACKUP_DIR/volumes/${name}_${DATE}.tar.gz"

  if [ ! -d "$source" ]; then
    echo "Skipping $name directory: $source does not exist."
    return
  fi

  echo "Backing up $name directory..."
  tar czf "$target" -C "$source" .
}

backup_postgres authentik-db authentik authentik authentik
backup_postgres n8n-db n8n n8n n8n

echo "Backing up Docker volumes..."
backup_volume caddy_caddy_data caddy
backup_volume n8n_n8n_data n8n_data
backup_directory /opt/180dc/authentik/data authentik_data

echo "Cleaning up old backups (keeping last $RETENTION_DAYS days)..."
find "$BACKUP_DIR/databases" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
find "$BACKUP_DIR/volumes" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" -delete

TOTAL_SIZE="$(du -sh "$BACKUP_DIR" | cut -f1)"
echo "=== Backup completed at $(date) ==="
echo "Total backup size: $TOTAL_SIZE"

echo ""
echo "Latest database backups:"
ls -lh "$BACKUP_DIR/databases" | grep "$DATE" || true
echo ""
echo "Latest volume backups:"
ls -lh "$BACKUP_DIR/volumes" | grep "$DATE" || true


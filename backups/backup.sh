#!/usr/bin/env bash
set -euo pipefail

umask 077

exec 9>/run/lock/180dc-backup.lock
if ! flock -n 9; then
  echo "Another backup is already running" >&2
  exit 1
fi

DATABASE_BACKUP_DIR="/opt/180dc/backups/databases"
VOLUME_BACKUP_DIR="/opt/180dc/backups/volumes"
LOG_BACKUP_DIR="/opt/180dc/backups/logs"
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

echo "=== Starting backup at $(date) ==="
install -d -m 700 "$DATABASE_BACKUP_DIR" "$VOLUME_BACKUP_DIR" "$LOG_BACKUP_DIR"

expire_backups() {
  local directory="$1"
  local pattern="$2"

  mapfile -t expired < <(
    find "$directory" -maxdepth 1 -type f -name "$pattern" -printf '%f\n' \
      | sort -r \
      | tail -n "+$((RETENTION_COUNT + 1))"
  )
  if [ "${#expired[@]}" -gt 0 ]; then
    printf '%s\0' "${expired[@]}" | xargs -0 -r -I{} rm -f -- "$directory/{}"
  fi
}

backup_postgres() {
  local container="$1"
  local user="$2"
  local db="$3"
  local name="$4"
  local target="$DATABASE_BACKUP_DIR/${name}_${DATE}.dump"
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

  expire_backups "$DATABASE_BACKUP_DIR" "${name}_*.dump"
}

backup_volume() {
  local volume="$1"
  local name="$2"
  local target="$VOLUME_BACKUP_DIR/${name}_${DATE}.tar.gz"
  local temporary="${target}.tmp"
  local mountpoint

  mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$volume" 2>/dev/null || true)"
  if [ -z "$mountpoint" ] || [ ! -d "$mountpoint" ]; then
    echo "Skipping $name volume backup: Docker volume $volume does not exist" >&2
    return 0
  fi

  echo "Backing up $name volume..."
  rm -f "$temporary"
  if ! nice -n 10 ionice -c 2 -n 7 tar \
    --one-file-system \
    --warning=no-file-changed \
    -C "$mountpoint" \
    -czf "$temporary" .; then
    rm -f "$temporary"
    return 1
  fi

  if ! tar -tzf "$temporary" >/dev/null; then
    echo "Backup validation failed for $name volume" >&2
    rm -f "$temporary"
    return 1
  fi

  mv "$temporary" "$target"
  expire_backups "$VOLUME_BACKUP_DIR" "${name}_*.tar.gz"
}

backup_docker_logs() {
  local target="$LOG_BACKUP_DIR/docker_${DATE}.tar.gz"
  local temporary="${target}.tmp"
  local scratch
  local container
  local containers=(
    caddy
    authentik-server
    authentik-worker
    n8n
    vexa-lite
    vexa-sso
    vexa-whisper
    odoo
  )

  scratch="$(mktemp -d)"

  for container in "${containers[@]}"; do
    if docker inspect "$container" >/dev/null 2>&1; then
      docker logs --timestamps "$container" > "$scratch/${container}.log" 2>&1 || true
    fi
  done

  echo "Backing up Docker logs..."
  rm -f "$temporary"
  if ! nice -n 10 ionice -c 2 -n 7 tar -C "$scratch" -czf "$temporary" .; then
    rm -f "$temporary"
    rm -rf "$scratch"
    return 1
  fi

  if ! tar -tzf "$temporary" >/dev/null; then
    echo "Backup validation failed for Docker logs" >&2
    rm -f "$temporary"
    rm -rf "$scratch"
    return 1
  fi

  rm -rf "$scratch"
  mv "$temporary" "$target"
  expire_backups "$LOG_BACKUP_DIR" "docker_*.tar.gz"
}

backup_postgres authentik-db "${AUTHENTIK_DB_USER:-authentik}" "${AUTHENTIK_DB_NAME:-authentik}" authentik
backup_postgres n8n-db "${N8N_DB_USER:-n8n}" "${N8N_DB_NAME:-n8n}" n8n
backup_postgres vexa-db "${VEXA_DB_USER:-vexa}" "${VEXA_DB_NAME:-vexa}" vexa
backup_postgres odoo-db "${ODOO_DB_USER:-odoo}" "${ODOO_DB_NAME:-student_society}" odoo

backup_volume caddy_caddy_data caddy_data
backup_volume caddy_caddy_config caddy_config
backup_volume n8n_n8n_data n8n_data
backup_volume odoo_odoo-web-data odoo_filestore
backup_volume vexa_recordings vexa_recordings
backup_volume vexa_tts_voices vexa_tts_voices
backup_volume vexa_whisper_data vexa_whisper_data
backup_docker_logs

# Custom-format dumps supersede legacy compressed SQL snapshots.
find "$DATABASE_BACKUP_DIR" -maxdepth 1 -type f -name '*.sql.gz' -delete

echo "=== Backup completed at $(date) ==="
du -sh /opt/180dc/backups
find "$DATABASE_BACKUP_DIR" "$VOLUME_BACKUP_DIR" "$LOG_BACKUP_DIR" \
  -maxdepth 1 -type f \( -name "*_${DATE}.dump" -o -name "*_${DATE}.tar.gz" \) \
  -printf '%p %k KiB\n' | sed "s#^/opt/180dc/backups/##" | sort

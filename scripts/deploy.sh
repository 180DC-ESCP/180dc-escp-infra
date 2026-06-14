#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE_ROOT="/opt/180dc"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "deploy.sh must run as root" >&2
    exit 1
  fi
}

sync_dir() {
  local src="$1"
  local dst="$2"
  install -d "$dst"
  rsync -a --delete \
    --exclude '.env' \
    --exclude 'data/' \
    --exclude 'certs/' \
    --exclude 'custom-templates/' \
    --exclude 'static/' \
    "$src"/ "$dst"/
}

sync_backups_config() {
  local src="$1"
  local dst="$2"
  install -d "$dst"
  rsync -a \
    --exclude 'databases/' \
    --exclude 'volumes/' \
    "$src"/ "$dst"/
}

wait_for_authentik() {
  local tries=60
  while [ "$tries" -gt 0 ]; do
    if docker inspect -f '{{.State.Health.Status}}' authentik-server 2>/dev/null | grep -qx healthy; then
      return 0
    fi
    if [ $((tries % 6)) -eq 0 ]; then
      echo "waiting for authentik-server health..."
    fi
    tries=$((tries - 1))
    sleep 5
  done
  echo "authentik-server did not become healthy" >&2
  return 1
}

wait_for_vexa() {
  local tries=60
  while [ "$tries" -gt 0 ]; do
    if ( : > /dev/tcp/127.0.0.1/8056 ) >/dev/null 2>&1; then
      return 0
    fi
    if [ $((tries % 6)) -eq 0 ]; then
      echo "waiting for vexa-lite on 127.0.0.1:8056..."
    fi
    tries=$((tries - 1))
    sleep 5
  done
  docker logs --tail 100 vexa-lite >&2 || true
  echo "vexa-lite did not become reachable" >&2
  return 1
}

wait_for_odoo() {
  local tries=60
  while [ "$tries" -gt 0 ]; do
    if docker inspect -f '{{.State.Health.Status}}' odoo-db 2>/dev/null | grep -qx healthy; then
      return 0
    fi
    if [ $((tries % 6)) -eq 0 ]; then
      echo "waiting for odoo-db health..."
    fi
    tries=$((tries - 1))
    sleep 5
  done
  echo "odoo-db did not become healthy" >&2
  return 1
}

require_root

docker network create proxy >/dev/null 2>&1 || true

install -d "$LIVE_ROOT/authentik" "$LIVE_ROOT/apps/n8n" "$LIVE_ROOT/apps/vexa" "$LIVE_ROOT/apps/odoo" "$LIVE_ROOT/caddy" "$LIVE_ROOT/backups"

if [ -x "$LIVE_ROOT/backups/backup.sh" ]; then
  "$LIVE_ROOT/backups/backup.sh"
fi

sync_dir "$ROOT/authentik" "$LIVE_ROOT/authentik"
sync_dir "$ROOT/n8n" "$LIVE_ROOT/apps/n8n"
sync_dir "$ROOT/vexa" "$LIVE_ROOT/apps/vexa"
sync_dir "$ROOT/odoo" "$LIVE_ROOT/apps/odoo"
sync_dir "$ROOT/caddy" "$LIVE_ROOT/caddy"
sync_backups_config "$ROOT/backups" "$LIVE_ROOT/backups"

install -d "$LIVE_ROOT/authentik/data" "$LIVE_ROOT/authentik/certs" "$LIVE_ROOT/authentik/custom-templates" "$LIVE_ROOT/caddy/static"

docker compose -f "$LIVE_ROOT/authentik/docker-compose.yml" --env-file "$LIVE_ROOT/authentik/.env" pull
docker compose -f "$LIVE_ROOT/authentik/docker-compose.yml" --env-file "$LIVE_ROOT/authentik/.env" up -d --remove-orphans
wait_for_authentik

docker compose -f "$LIVE_ROOT/authentik/docker-compose.yml" --env-file "$LIVE_ROOT/authentik/.env" exec -T server \
  ak shell < "$LIVE_ROOT/authentik/apply-config.py"

docker compose -f "$LIVE_ROOT/apps/n8n/docker-compose.yml" --env-file "$LIVE_ROOT/apps/n8n/.env" pull
docker compose -f "$LIVE_ROOT/apps/n8n/docker-compose.yml" --env-file "$LIVE_ROOT/apps/n8n/.env" up -d --remove-orphans

docker compose -f "$LIVE_ROOT/apps/vexa/docker-compose.yml" --env-file "$LIVE_ROOT/apps/vexa/.env" pull
docker compose -f "$LIVE_ROOT/apps/vexa/docker-compose.yml" --env-file "$LIVE_ROOT/apps/vexa/.env" up -d --remove-orphans
wait_for_vexa

docker compose -f "$LIVE_ROOT/apps/odoo/docker-compose.yml" --env-file "$LIVE_ROOT/apps/odoo/.env" pull
docker compose -f "$LIVE_ROOT/apps/odoo/docker-compose.yml" --env-file "$LIVE_ROOT/apps/odoo/.env" up -d --remove-orphans
wait_for_odoo

docker compose -f "$LIVE_ROOT/caddy/docker-compose.yml" pull
docker compose -f "$LIVE_ROOT/caddy/docker-compose.yml" up -d --remove-orphans

docker image prune -a -f >/dev/null
docker builder prune -f >/dev/null

"$ROOT/scripts/verify.sh"

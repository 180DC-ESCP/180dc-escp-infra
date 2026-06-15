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

dump_diagnostics() {
  local exit_code="$?"
  echo "deploy failed with exit code $exit_code" >&2
  docker ps --format '{{.Names}} {{.Status}}' | sort >&2 || true
  for container in caddy authentik-server n8n vexa-lite vexa-sso vexa-whisper odoo; do
    if docker inspect "$container" >/dev/null 2>&1; then
      echo "---- logs: $container ----" >&2
      docker logs --tail 120 "$container" >&2 || true
    fi
  done
  exit "$exit_code"
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

env_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' "$file"
}

configure_odoo_secrets() {
  local env_file="$LIVE_ROOT/apps/odoo/.env"
  local config_file="$LIVE_ROOT/apps/odoo/config/odoo.conf"
  local admin_password
  local tmp

  admin_password="$(env_value ODOO_ADMIN_PASSWORD "$env_file")"
  if [ -z "$admin_password" ]; then
    echo "ODOO_ADMIN_PASSWORD is missing from $env_file" >&2
    return 1
  fi

  tmp="$(mktemp)"
  awk -v admin_password="$admin_password" '
    !/^[[:space:]]*admin_passwd[[:space:]]*=/ { print }
    END { print "admin_passwd = " admin_password }
  ' "$config_file" > "$tmp"
  install -m 644 "$tmp" "$config_file"
  rm -f "$tmp"
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
    if docker inspect -f '{{.State.Status}}' vexa-lite 2>/dev/null | grep -qx running \
      && curl -fsS http://127.0.0.1:8056/ >/dev/null 2>&1; then
      return 0
    fi
    if [ $((tries % 6)) -eq 0 ]; then
      echo "waiting for vexa-lite services..."
    fi
    tries=$((tries - 1))
    sleep 5
  done
  docker logs --tail 100 vexa-lite >&2 || true
  echo "vexa-lite did not become reachable" >&2
  return 1
}

wait_for_container_running() {
  local container="$1"
  local tries=60
  while [ "$tries" -gt 0 ]; do
    if docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null | grep -qx running; then
      return 0
    fi
    if [ $((tries % 6)) -eq 0 ]; then
      echo "waiting for $container to run..."
    fi
    tries=$((tries - 1))
    sleep 5
  done
  docker logs --tail 100 "$container" >&2 || true
  echo "$container did not stay running" >&2
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

odoo_database_initialized() {
  docker exec odoo-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "\dt public.ir_module_module"' 2>/dev/null \
    | grep -q ir_module_module
}

trap dump_diagnostics ERR

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
configure_odoo_secrets

install -d "$LIVE_ROOT/authentik/data" "$LIVE_ROOT/authentik/certs" "$LIVE_ROOT/authentik/custom-templates"

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
docker compose -f "$LIVE_ROOT/apps/odoo/docker-compose.yml" --env-file "$LIVE_ROOT/apps/odoo/.env" up -d db
wait_for_odoo
if odoo_database_initialized; then
  echo "Odoo database already initialized."
else
  echo "Initializing Odoo database."
  docker compose -f "$LIVE_ROOT/apps/odoo/docker-compose.yml" --env-file "$LIVE_ROOT/apps/odoo/.env" --profile init run --rm init
fi
docker compose -f "$LIVE_ROOT/apps/odoo/docker-compose.yml" --env-file "$LIVE_ROOT/apps/odoo/.env" up -d --remove-orphans odoo
wait_for_container_running odoo

docker compose -f "$LIVE_ROOT/caddy/docker-compose.yml" pull
docker compose -f "$LIVE_ROOT/caddy/docker-compose.yml" up -d --remove-orphans
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

docker image prune -a -f >/dev/null
docker builder prune -f >/dev/null

"$ROOT/scripts/verify.sh"

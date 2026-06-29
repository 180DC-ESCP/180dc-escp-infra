#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT/.local"
LOCAL_FULL_BASE_DOMAIN="${LOCAL_FULL_BASE_DOMAIN:-localhost:8080}"

local_full_host() {
  printf '%s\n' "${LOCAL_FULL_BASE_DOMAIN%%:*}"
}

render_local() {
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "ansible-playbook is required. Install ansible-core or run: uv tool install ansible-core==2.19.4" >&2
    return 1
  fi

  ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg" \
    LOCAL_FULL_BASE_DOMAIN="$LOCAL_FULL_BASE_DOMAIN" \
    ansible-playbook "$ROOT/ansible/local.yml"
}

dc_authentik() {
  docker compose \
    --project-directory "$ROOT/authentik" \
    -f "$ROOT/authentik/docker-compose.yml" \
    -f "$LOCAL_DIR/authentik.compose.yml" \
    --env-file "$ROOT/authentik/.env" \
    "$@"
}

dc_n8n() {
  docker compose \
    --project-directory "$ROOT/n8n" \
    -f "$ROOT/n8n/docker-compose.yml" \
    -f "$LOCAL_DIR/n8n.compose.yml" \
    --env-file "$ROOT/n8n/.env" \
    "$@"
}

dc_odoo() {
  docker compose \
    --project-directory "$ROOT/odoo" \
    -f "$ROOT/odoo/docker-compose.yml" \
    -f "$LOCAL_DIR/odoo.compose.yml" \
    --env-file "$ROOT/odoo/.env" \
    "$@"
}

dc_caddy_full() {
  docker compose \
    --project-directory "$ROOT/caddy" \
    -f "$LOCAL_DIR/caddy.compose.yml" \
    --env-file "$ROOT/caddy/.env" \
    "$@"
}

dc_kuma() {
  docker compose \
    --project-directory "$ROOT/uptime-kuma" \
    -f "$ROOT/uptime-kuma/docker-compose.yml" \
    --env-file "$ROOT/uptime-kuma/.env" \
    "$@"
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

wait_for_container_running() {
  local container="$1"
  local tries=90
  while [ "$tries" -gt 0 ]; do
    if docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null | grep -qx running; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 2
  done
  docker logs --tail 120 "$container" >&2 || true
  echo "$container did not start" >&2
  return 1
}

wait_for_container_healthy() {
  local container="$1"
  local tries="${2:-90}"
  while [ "$tries" -gt 0 ]; do
    if docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null | grep -qx healthy; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 2
  done
  docker logs --tail 120 "$container" >&2 || true
  echo "$container did not become healthy" >&2
  return 1
}

wait_for_authentik() {
  wait_for_container_healthy authentik-server 120
}

wait_for_odoo_db() {
  wait_for_container_healthy odoo-db 90
}

odoo_database_initialized() {
  docker exec odoo-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "\dt public.ir_module_module"' 2>/dev/null \
    | grep -q ir_module_module
}

create_local_networks() {
  docker network create caddy-authentik >/dev/null 2>&1 || true
  docker network create caddy-n8n >/dev/null 2>&1 || true
  docker network create caddy-odoo >/dev/null 2>&1 || true
  docker network create caddy-kuma >/dev/null 2>&1 || true
}

start_core_apps() {
  dc_authentik up -d
  wait_for_authentik
  dc_authentik exec -T server ak shell < "$ROOT/authentik/apply-config.py"

  dc_n8n up -d

  dc_odoo up -d db
  wait_for_odoo_db
  if odoo_database_initialized; then
    echo "Odoo database already initialized."
  else
    echo "Initializing local Odoo database."
    dc_odoo --profile init run --rm init
  fi
  dc_odoo up -d odoo
  wait_for_container_running odoo
}

check_url() {
  local url="$1"
  local code=""

  for attempt in 1 2 3 4 5; do
    if code="$(curl -sS -o /dev/null -w '%{http_code}' "$url")"; then
      break
    fi
    echo "retrying $url after curl failure ($attempt/5)" >&2
    sleep 5
  done

  if [ -z "$code" ]; then
    echo "curl failed for $url" >&2
    return 1
  fi

  case "$code" in
    200|302|303|403|404)
      echo "ok $code $url"
      ;;
    *)
      echo "unexpected HTTP $code for $url" >&2
      return 1
      ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: scripts/local.sh <command>

Commands:
  init        Render local .env files and Compose overrides
  up          Start Authentik, n8n, and Odoo with direct localhost ports
  verify      Check direct localhost ports
  full-up     Start Authentik, Caddy, n8n, Odoo, and Uptime Kuma locally
  full-verify Check the local full stack through Caddy
  full-down   Stop the local full stack while keeping volumes
  full-reset  Stop the local full stack and delete local Docker volumes/secrets
  status      Show local container status
  logs        Follow logs for running local services
  down        Stop local services while keeping volumes
  reset       Stop local services and delete local Docker volumes/secrets

Direct routes:
  authentik: http://localhost:9000
  n8n:       http://localhost:5678
  odoo:      http://localhost:8069

Full stack routes:
  authentik: http://login.localhost:8080
  n8n:       http://n8n.localhost:8080
  hooks:     http://hooks.localhost:8080
  odoo:      http://odoo.localhost:8080
  kuma:      http://kuma.localhost:8080

Set LOCAL_FULL_BASE_DOMAIN to override the full-stack host and port.
Google SSO requires real OAuth credentials and matching redirect URIs.
EOF
}

cmd_init() {
  render_local
  echo "Local files are ready. Generated files live under $LOCAL_DIR and ignored .env files."
}

cmd_up() {
  render_local
  create_local_networks

  echo "Starting local stack (direct ports, no Caddy)..."
  echo "  authentik: http://localhost:9000"
  echo "  n8n:       http://localhost:5678"
  echo "  odoo:      http://localhost:8069"
  echo ""

  start_core_apps
  cmd_verify
}

cmd_full_up() {
  render_local
  create_local_networks

  echo "Starting local full stack (without Vexa)..."
  echo "  authentik: http://login.$LOCAL_FULL_BASE_DOMAIN"
  echo "  n8n:       http://n8n.$LOCAL_FULL_BASE_DOMAIN"
  echo "  hooks:     http://hooks.$LOCAL_FULL_BASE_DOMAIN"
  echo "  odoo:      http://odoo.$LOCAL_FULL_BASE_DOMAIN"
  echo "  kuma:      http://kuma.$LOCAL_FULL_BASE_DOMAIN"
  echo "  direct authentik admin: http://localhost:9000"
  echo ""

  start_core_apps

  dc_kuma up -d
  wait_for_container_healthy uptime-kuma 120

  dc_caddy_full up -d
  wait_for_container_healthy caddy 60

  cmd_full_verify
  echo "Authentik bootstrap email is in $ROOT/authentik/.env as AUTHENTIK_BOOTSTRAP_EMAIL."
  echo "Authentik bootstrap password is in $LOCAL_DIR/secrets/authentik_bootstrap_password."
}

cmd_verify() {
  docker ps --format '{{.Names}} {{.Status}}' | sort
  check_url "http://localhost:9000/"
  check_url "http://localhost:5678/"
  check_url "http://localhost:8069/"
}

cmd_full_verify() {
  docker ps --format '{{.Names}} {{.Status}}' | sort
  check_url "http://login.$LOCAL_FULL_BASE_DOMAIN/-/health/live/"
  check_url "http://n8n.$LOCAL_FULL_BASE_DOMAIN/"
  check_url "http://hooks.$LOCAL_FULL_BASE_DOMAIN/webhook/__verify_public_hooks__"
  check_url "http://odoo.$LOCAL_FULL_BASE_DOMAIN/"
  check_url "http://kuma.$LOCAL_FULL_BASE_DOMAIN/"
}

cmd_status() {
  docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | sort
}

cmd_logs() {
  if container_exists caddy; then dc_caddy_full logs -f & fi
  if container_exists uptime-kuma; then dc_kuma logs -f & fi
  if container_exists odoo || container_exists odoo-db; then dc_odoo logs -f & fi
  if container_exists n8n || container_exists n8n-db; then dc_n8n logs -f & fi
  if container_exists authentik-server || container_exists authentik-db; then dc_authentik logs -f & fi
  wait
}

cmd_down() {
  render_local
  dc_caddy_full down --remove-orphans || true
  dc_kuma down --remove-orphans || true
  dc_odoo down --remove-orphans || true
  dc_n8n down --remove-orphans || true
  dc_authentik down --remove-orphans || true
}

cmd_reset() {
  render_local
  dc_caddy_full down -v --remove-orphans || true
  dc_kuma down -v --remove-orphans || true
  dc_odoo down -v --remove-orphans || true
  dc_n8n down -v --remove-orphans || true
  dc_authentik down -v --remove-orphans || true
  rm -rf "$LOCAL_DIR"
}

case "${1:-}" in
  init) cmd_init ;;
  up) cmd_up ;;
  verify) cmd_verify ;;
  full-up) cmd_full_up ;;
  full-verify) cmd_full_verify ;;
  full-down) cmd_down ;;
  full-reset) cmd_reset ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  down) cmd_down ;;
  reset) cmd_reset ;;
  -h|--help|help|"") usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac

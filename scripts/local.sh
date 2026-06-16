#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT/.local"

random_hex() {
  openssl rand -hex 32
}

env_get() {
  local file="$1"
  local key="$2"
  awk -F= -v key="$key" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' "$file"
}

env_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { seen = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      seen = 1
      next
    }
    { print }
    END {
      if (!seen) {
        print key "=" value
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

env_set_if_placeholder() {
  local file="$1"
  local key="$2"
  local value="$3"
  local current
  current="$(env_get "$file" "$key")"
  if [ -z "$current" ] || [ "$current" = "replace-me" ]; then
    env_set "$file" "$key" "$value"
  fi
}

ensure_env() {
  local app="$1"
  local file="$ROOT/$app/.env"
  local example="$ROOT/$app/.env.example"
  if [ ! -f "$file" ]; then
    cp "$example" "$file"
  fi
}

ensure_config_env() {
  local file="$ROOT/config.env"
  local example="$ROOT/config.env.example"
  if [ ! -f "$file" ]; then
    cp "$example" "$file"
  fi
}

ensure_envs() {
  ensure_config_env
  ensure_env authentik
  ensure_env n8n
  ensure_env odoo
  ensure_env vexa

  local config_file="$ROOT/config.env"
  env_set_if_placeholder "$config_file" BASE_DOMAIN "180dc-escp.org"
  env_set_if_placeholder "$config_file" AUTHENTIK_ALLOWED_EMAIL_DOMAIN "180dc.org"
  env_set_if_placeholder "$config_file" PLATFORM_ADMIN_EMAIL "escp@180dc.org"

  env_set_if_placeholder "$ROOT/authentik/.env" PG_PASS "$(random_hex)"
  env_set_if_placeholder "$ROOT/authentik/.env" AUTHENTIK_SECRET_KEY "$(random_hex)"
  env_set_if_placeholder "$ROOT/authentik/.env" AUTHENTIK_BOOTSTRAP_PASSWORD "$(random_hex)"
  env_set_if_placeholder "$ROOT/authentik/.env" AUTHENTIK_BOOTSTRAP_TOKEN "$(random_hex)"

  env_set_if_placeholder "$ROOT/n8n/.env" POSTGRES_PASSWORD "$(random_hex)"
  env_set_if_placeholder "$ROOT/n8n/.env" N8N_ENCRYPTION_KEY "$(random_hex)"

  env_set_if_placeholder "$ROOT/odoo/.env" POSTGRES_PASSWORD "$(random_hex)"
  env_set_if_placeholder "$ROOT/odoo/.env" ODOO_ADMIN_PASSWORD "$(random_hex)"

  local sso_shared_secret
  sso_shared_secret="$(env_get "$config_file" SSO_SHARED_SECRET)"
  if [ -z "$sso_shared_secret" ] || [ "$sso_shared_secret" = "replace-me" ]; then
    sso_shared_secret="$(random_hex)"
    env_set "$config_file" SSO_SHARED_SECRET "$sso_shared_secret"
  fi

  local base_domain
  base_domain="$(env_get "$config_file" BASE_DOMAIN)"
  local allowed_domain
  allowed_domain="$(env_get "$config_file" AUTHENTIK_ALLOWED_EMAIL_DOMAIN)"
  local platform_admin
  platform_admin="$(env_get "$config_file" PLATFORM_ADMIN_EMAIL)"

  env_set "$ROOT/authentik/.env" AUTHENTIK_BASE_URL "https://login.${base_domain}"
}

render_local_files() {
  local config_file="$ROOT/config.env"
  local base_domain
  base_domain="$(env_get "$config_file" BASE_DOMAIN)"
  local odoo_admin_password
  mkdir -p "$LOCAL_DIR/odoo-config"

  # Local port-based overrides - expose services directly, skip Caddy
  cat > "$LOCAL_DIR/authentik.compose.yml" <<EOF
services:
  server:
    ports:
      - "127.0.0.1:9000:9000"
EOF

  cat > "$LOCAL_DIR/n8n.compose.yml" <<EOF
services:
  n8n:
    ports:
      - "127.0.0.1:5678:5678"
EOF

  odoo_admin_password="$(env_get "$ROOT/odoo/.env" ODOO_ADMIN_PASSWORD)"
  awk -v admin_password="$odoo_admin_password" '
    !/^[[:space:]]*admin_passwd[[:space:]]*=/ { print }
    END { print "admin_passwd = " admin_password }
  ' "$ROOT/odoo/config/odoo.conf" > "$LOCAL_DIR/odoo-config/odoo.conf"

  cat > "$LOCAL_DIR/odoo.compose.yml" <<EOF
services:
  odoo:
    volumes:
      - $LOCAL_DIR/odoo-config/odoo.conf:/etc/odoo/odoo.conf:ro
    ports:
      - "127.0.0.1:8069:8069"
  init:
    volumes:
      - $LOCAL_DIR/odoo-config/odoo.conf:/etc/odoo/odoo.conf:ro
      - $ROOT:/mnt/import:ro
EOF

  cat > "$LOCAL_DIR/vexa.compose.yml" <<EOF
services:
  vexa-lite:
    ports:
      - "127.0.0.1:3000:3000"
      - "127.0.0.1:8056:8056"
  vexa-sso:
    ports:
      - "127.0.0.1:8080:8080"
EOF
}



dc_authentik() {
  docker compose --project-directory "$ROOT/authentik" -f "$ROOT/authentik/docker-compose.yml" -f "$LOCAL_DIR/authentik.compose.yml" --env-file "$ROOT/config.env" --env-file "$ROOT/authentik/.env" "$@"
}

dc_n8n() {
  docker compose --project-directory "$ROOT/n8n" -f "$ROOT/n8n/docker-compose.yml" -f "$LOCAL_DIR/n8n.compose.yml" --env-file "$ROOT/config.env" --env-file "$ROOT/n8n/.env" "$@"
}

dc_odoo() {
  docker compose --project-directory "$ROOT/odoo" -f "$ROOT/odoo/docker-compose.yml" -f "$LOCAL_DIR/odoo.compose.yml" --env-file "$ROOT/config.env" --env-file "$ROOT/odoo/.env" "$@"
}

dc_vexa() {
  docker compose --project-directory "$ROOT/vexa" -f "$ROOT/vexa/docker-compose.yml" -f "$LOCAL_DIR/vexa.compose.yml" --env-file "$ROOT/config.env" --env-file "$ROOT/vexa/.env" "$@"
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

wait_for_authentik() {
  local tries=120
  while [ "$tries" -gt 0 ]; do
    if docker inspect -f '{{.State.Health.Status}}' authentik-server 2>/dev/null | grep -qx healthy; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 3
  done
  docker logs --tail 120 authentik-server >&2 || true
  echo "authentik-server did not become ready" >&2
  return 1
}

wait_for_odoo_db() {
  local tries=90
  while [ "$tries" -gt 0 ]; do
    if docker inspect -f '{{.State.Health.Status}}' odoo-db 2>/dev/null | grep -qx healthy; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 2
  done
  docker logs --tail 120 odoo-db >&2 || true
  echo "odoo-db did not become healthy" >&2
  return 1
}

odoo_database_initialized() {
  docker exec odoo-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "\dt public.ir_module_module"' 2>/dev/null \
    | grep -q ir_module_module
}

usage() {
  cat <<'EOF'
Usage: scripts/local.sh <command>

Commands:
  init      Create local .env files and generated local overrides
  up        Start the local stack (port-based, no Caddy)
  verify    Check local containers and ports
  status    Show local container status
  logs      Follow logs for all local services
  down      Stop local services while keeping volumes
  reset     Stop local services and delete local Docker volumes

Services are accessible on:
  authentik: http://localhost:9000
  n8n:       http://localhost:5678
  odoo:      http://localhost:8069
  vexa:      http://localhost:3000
  vexa-api:  http://localhost:8056

Google SSO is not available locally (requires real OAuth credentials
and matching redirect URIs). Use for development only.
EOF
}

cmd_init() {
  ensure_envs
  render_local_files
  echo "Local files are ready. Generated files live under $LOCAL_DIR and are gitignored."
}

cmd_up() {
  ensure_envs
  render_local_files

  echo "Starting local stack (port-based, no Caddy)..."
  echo "  authentik: http://localhost:9000"
  echo "  n8n:       http://localhost:5678"
  echo "  odoo:      http://localhost:8069"
  echo "  vexa:      http://localhost:3000"
  echo "  vexa-api:  http://localhost:8056"
  echo ""

  docker network create proxy >/dev/null 2>&1 || true

  dc_authentik up -d
  wait_for_authentik
  dc_authentik exec -T server ak shell < "$ROOT/authentik/apply-config.py"

  dc_n8n up -d

  dc_vexa up -d
  wait_for_container_running vexa-lite

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

  cmd_verify
}

cmd_verify() {
  docker ps --format '{{.Names}} {{.Status}}' | sort
  for url in \
    "http://localhost:9000/" \
    "http://localhost:5678/" \
    "http://localhost:8069/" \
    "http://localhost:3000/" \
    "http://localhost:8056/"
  do
    code=""
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
    case "$url:$code" in
      *:200|*:302|*:403|*:404)
        echo "ok $code $url"
        ;;
      *)
        echo "unexpected HTTP $code for $url" >&2
        return 1
        ;;
    esac
  done
}

cmd_status() {
  docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | sort
}

cmd_logs() {
  dc_odoo logs -f &
  dc_n8n logs -f &
  dc_vexa logs -f &
  dc_authentik logs -f &
  wait
}

cmd_down() {
  ensure_envs
  render_local_files
  dc_odoo down --remove-orphans || true
  dc_n8n down --remove-orphans || true
  dc_vexa down --remove-orphans || true
  dc_authentik down --remove-orphans || true
}

cmd_reset() {
  ensure_envs
  render_local_files
  dc_odoo down -v --remove-orphans || true
  dc_n8n down -v --remove-orphans || true
  dc_vexa down -v --remove-orphans || true
  dc_authentik down -v --remove-orphans || true
  rm -rf "$LOCAL_DIR"
}

case "${1:-}" in
  init) cmd_init ;;
  up) cmd_up ;;
  verify) cmd_verify ;;
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

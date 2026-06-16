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

  cat > "$LOCAL_DIR/caddy.compose.yml" <<EOF
services:
  caddy:
    volumes:
      - $ROOT/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
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
  init:
    volumes:
      - $LOCAL_DIR/odoo-config/odoo.conf:/etc/odoo/odoo.conf:ro
      - $ROOT:/mnt/import:ro
EOF
}

get_hosts() {
  local config_file="$ROOT/config.env"
  local base_domain
  base_domain="$(env_get "$config_file" BASE_DOMAIN)"
  echo "login.${base_domain} n8n.${base_domain} hooks.${base_domain} vexa.${base_domain} vexa-api.${base_domain} odoo.${base_domain}"
}

check_hosts() {
  local hosts
  hosts="$(get_hosts)"
  local missing=()
  local host
  for host in $hosts; do
    if ! awk -v host="$host" '$1 == "127.0.0.1" { for (i = 2; i <= NF; i++) if ($i == host) found = 1 } END { exit found ? 0 : 1 }' /etc/hosts; then
      missing+=("$host")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing /etc/hosts entries for local routing:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo >&2
    echo "Add this line with sudo:" >&2
    printf '127.0.0.1'
    printf ' %s' $hosts
    printf '\n'
    return 1
  fi
}

require_google_oauth() {
  local client_id
  local client_secret
  client_id="$(env_get "$ROOT/authentik/.env" GOOGLE_OAUTH_CLIENT_ID)"
  client_secret="$(env_get "$ROOT/authentik/.env" GOOGLE_OAUTH_CLIENT_SECRET)"
  if [ -z "$client_id" ] || [ "$client_id" = "replace-me" ] || [ -z "$client_secret" ] || [ "$client_secret" = "replace-me" ]; then
    local config_file="$ROOT/config.env"
    local base_domain
    base_domain="$(env_get "$config_file" BASE_DOMAIN)"
    echo "authentik/.env needs real GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET for full local SSO." >&2
    echo "Use redirect URI: https://login.${base_domain}/source/oauth/callback/google/" >&2
    return 1
  fi
}

dc_authentik() {
  docker compose --project-directory "$ROOT/authentik" -f "$ROOT/authentik/docker-compose.yml" --env-file "$ROOT/config.env" --env-file "$ROOT/authentik/.env" "$@"
}

dc_n8n() {
  docker compose --project-directory "$ROOT/n8n" -f "$ROOT/n8n/docker-compose.yml" --env-file "$ROOT/config.env" --env-file "$ROOT/n8n/.env" "$@"
}

dc_odoo() {
  docker compose --project-directory "$ROOT/odoo" -f "$ROOT/odoo/docker-compose.yml" -f "$LOCAL_DIR/odoo.compose.yml" --env-file "$ROOT/config.env" --env-file "$ROOT/odoo/.env" "$@"
}

dc_caddy() {
  docker compose --project-directory "$ROOT/caddy" -f "$ROOT/caddy/docker-compose.yml" -f "$LOCAL_DIR/caddy.compose.yml" --env-file "$ROOT/config.env" "$@"
}

dc_vexa() {
  docker compose --project-directory "$ROOT/vexa" -f "$ROOT/vexa/docker-compose.yml" --env-file "$ROOT/config.env" --env-file "$ROOT/vexa/.env" "$@"
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
  local config_file="$ROOT/config.env"
  local base_domain="180dc-escp.org"
  if [ -f "$config_file" ]; then
    base_domain="$(env_get "$config_file" BASE_DOMAIN)"
  fi
  cat <<EOF
Usage: scripts/local.sh <command>

Commands:
  init      Create local .env files and generated local overrides
  up        Start the local stack and apply Authentik config
  verify    Check local containers and public routes
  status    Show local container status
  logs      Follow logs for all local services
  down      Stop local services while keeping volumes
  reset     Stop local services and delete local Docker volumes

Before "up", add these hostnames to /etc/hosts pointing at 127.0.0.1:
  login.${base_domain} n8n.${base_domain} hooks.${base_domain} vexa.${base_domain} vexa-api.${base_domain} odoo.${base_domain}

Full SSO requires real GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET
in authentik/.env. Keep .env files local; they are gitignored.
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
  check_hosts
  require_google_oauth

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

  dc_caddy up -d
  wait_for_container_running caddy
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
  cmd_verify
}

cmd_verify() {
  local config_file="$ROOT/config.env"
  local base_domain
  base_domain="$(env_get "$config_file" BASE_DOMAIN)"

  docker ps --format '{{.Names}} {{.Status}}' | sort
  for url in \
    "https://login.${base_domain}/" \
    "https://n8n.${base_domain}/" \
    "https://hooks.${base_domain}/webhook/__verify_public_hooks__" \
    "https://vexa.${base_domain}/" \
    "https://vexa-api.${base_domain}/admin/users" \
    "https://odoo.${base_domain}/"
  do
    code=""
    for attempt in 1 2 3 4 5; do
      if code="$(curl -k -sS -o /dev/null -w '%{http_code}' "$url")"; then
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
      *login*:200|*login*:302|*:302|*hooks*:404|*vexa*:302|*vexa-api*:403)
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
  dc_caddy logs -f &
  dc_odoo logs -f &
  dc_n8n logs -f &
  dc_vexa logs -f &
  dc_authentik logs -f &
  wait
}

cmd_down() {
  ensure_envs
  render_local_files
  dc_caddy down --remove-orphans || true
  dc_odoo down --remove-orphans || true
  dc_n8n down --remove-orphans || true
  dc_vexa down --remove-orphans || true
  dc_authentik down --remove-orphans || true
}

cmd_reset() {
  ensure_envs
  render_local_files
  dc_caddy down -v --remove-orphans || true
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

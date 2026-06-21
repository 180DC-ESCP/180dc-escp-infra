#!/usr/bin/env bash
set -euo pipefail

LIVE_ROOT="/opt/180dc"
CONFIG_FILE="$LIVE_ROOT/config.env"
BASE_DOMAIN="180dc-escp.org"

if [ -f "$CONFIG_FILE" ]; then
  base_from_config="$(awk -F= -v key="BASE_DOMAIN" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' "$CONFIG_FILE")"
  if [ -n "$base_from_config" ]; then
    BASE_DOMAIN="$base_from_config"
  fi
fi

require_running() {
  local container="$1"
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]; then
    echo "container is not running: $container" >&2
    return 1
  fi
  echo "ok running $container"
}

require_healthy() {
  local container="$1"
  if [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true)" != "healthy" ]; then
    echo "container is not healthy: $container" >&2
    return 1
  fi
  echo "ok healthy $container"
}

container_env_value() {
  local container="$1"
  local key="$2"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" \
    | awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2) }'
}

require_shared_sso_secret() {
  local expected
  local container
  local actual

  expected="$(container_env_value caddy SSO_SHARED_SECRET)"
  if [ -z "$expected" ]; then
    echo "caddy SSO shared secret is missing" >&2
    return 1
  fi

  for container in n8n vexa-sso odoo; do
    actual="$(container_env_value "$container" SSO_SHARED_SECRET)"
    if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
      echo "SSO shared secret mismatch: caddy and $container" >&2
      return 1
    fi
    echo "ok shared SSO secret caddy/$container"
  done
}

expect_origin_code() {
  local host="$1"
  local path="$2"
  local expected="$3"
  local code
  code="$(curl -ksS --connect-timeout 5 --max-time 15 \
    --resolve "$host:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "https://$host$path")"
  if [ "$code" != "$expected" ]; then
    echo "unexpected origin HTTP $code for https://$host$path; expected $expected" >&2
    return 1
  fi
  echo "ok origin $code https://$host$path"
}

for container in \
  authentik-server authentik-worker authentik-db \
  n8n n8n-db \
  vexa-lite vexa-sso vexa-whisper vexa-db \
  odoo odoo-db caddy
do
  require_running "$container"
done

for container in \
  authentik-server authentik-worker authentik-db \
  n8n n8n-db \
  vexa-lite vexa-sso vexa-whisper vexa-db \
  odoo odoo-db caddy
do
  require_healthy "$container"
done

require_shared_sso_secret

# These probes reach the applications themselves, independently of Authentik
# redirects and Cloudflare challenge decisions.
docker exec n8n wget -q --spider http://127.0.0.1:5678/
echo "ok direct n8n"
docker exec odoo curl -fsS http://127.0.0.1:8069/web/login >/dev/null
echo "ok direct odoo"
curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:8056/docs >/dev/null
echo "ok direct vexa API"
docker exec vexa-sso python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3)"
echo "ok direct vexa SSO"
docker exec caddy wget -q --spider http://authentik-server:9000/-/health/live/
echo "ok direct authentik"
docker exec caddy wget -q --spider http://127.0.0.1:2019/config/
echo "ok direct caddy"

# Route through the local Caddy listener with correct TLS SNI. This validates
# the production routing without depending on Cloudflare or a clearance cookie.
expect_origin_code "login.${BASE_DOMAIN}" "/" 302
expect_origin_code "n8n.${BASE_DOMAIN}" "/" 302
expect_origin_code "hooks.${BASE_DOMAIN}" "/webhook/__verify_public_hooks__" 404
expect_origin_code "vexa.${BASE_DOMAIN}" "/" 302
expect_origin_code "vexa-api.${BASE_DOMAIN}" "/admin/users" 403
expect_origin_code "odoo.${BASE_DOMAIN}" "/" 302

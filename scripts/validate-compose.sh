#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_env() {
  local target="$1"
  {
    printf 'BASE_DOMAIN=180dc-escp.org\n'
    printf 'AUTHENTIK_ALLOWED_EMAIL_DOMAIN=180dc.org\n'
    printf 'AUTHENTIK_BASE_URL=https://login.180dc-escp.org\n'
    printf 'PLATFORM_ADMIN_EMAIL=escp@180dc.org\n'
    printf 'GOOGLE_OAUTH_CLIENT_ID=ci-google-client-id\n'
    printf 'GOOGLE_OAUTH_CLIENT_SECRET=ci-google-client-secret\n'
    printf 'PG_USER=authentik\n'
    printf 'PG_DB=authentik\n'
    printf 'PG_PASS=ci-authentik-db-password\n'
    printf 'AUTHENTIK_SECRET_KEY=ci-authentik-secret-key-with-enough-length\n'
    printf 'AUTHENTIK_ERROR_REPORTING__ENABLED=false\n'
    printf 'AUTHENTIK_EMAIL__HOST=localhost\n'
    printf 'AUTHENTIK_EMAIL__PORT=25\n'
    printf 'AUTHENTIK_EMAIL__USERNAME=\n'
    printf 'AUTHENTIK_EMAIL__PASSWORD=\n'
    printf 'AUTHENTIK_EMAIL__USE_TLS=false\n'
    printf 'AUTHENTIK_EMAIL__FROM=\n'
    printf 'POSTGRES_USER=ci-user\n'
    printf 'POSTGRES_PASSWORD=ci-postgres-password\n'
    printf 'POSTGRES_DB=ci-db\n'
    printf 'N8N_HOST=n8n.180dc-escp.org\n'
    printf 'N8N_EDITOR_BASE_URL=https://n8n.180dc-escp.org\n'
    printf 'N8N_PORT=5678\n'
    printf 'N8N_PROTOCOL=https\n'
    printf 'WEBHOOK_URL=https://hooks.180dc-escp.org\n'
    printf 'N8N_ENCRYPTION_KEY=ci-n8n-encryption-key-with-enough-length\n'
    printf 'GENERIC_TIMEZONE=Europe/Berlin\n'
    printf 'TZ=Europe/Berlin\n'
    printf 'N8N_EMAIL_MODE=\n'
    printf 'N8N_SMTP_HOST=\n'
    printf 'N8N_SMTP_PORT=587\n'
    printf 'N8N_SMTP_USER=\n'
    printf 'N8N_SMTP_PASS=\n'
    printf 'N8N_SMTP_SENDER=\n'
    printf 'N8N_SMTP_SSL=false\n'
    printf 'N8N_SECURE_COOKIE=true\n'
    printf 'N8N_PROXY_HOPS=1\n'
    printf 'N8N_SSO_SECRET=ci-n8n-sso-secret-with-enough-length\n'
    printf 'DB_NAME=vexa\n'
    printf 'DB_USER=vexa\n'
    printf 'DB_PASSWORD=ci-vexa-db-password\n'
    printf 'ADMIN_TOKEN=ci-vexa-admin-token-with-enough-length\n'
    printf 'TRANSCRIPTION_SERVICE_URL=http://whisper:9000/v1/audio/transcriptions\n'
    printf 'TRANSCRIPTION_SERVICE_TOKEN=local-whisper\n'
    printf 'TRANSCRIBER_URL=http://whisper:9000/v1/audio/transcriptions\n'
    printf 'TRANSCRIBER_API_KEY=local-whisper\n'
    printf 'OPENAI_API_KEY=local-whisper\n'
    printf 'SKIP_TRANSCRIPTION_CHECK=false\n'
    printf 'WHISPER_MODEL=base\n'
    printf 'WHISPER_LANGUAGE=auto\n'
    printf 'WHISPER_DEVICE=cpu\n'
    printf 'WHISPER_COMPUTE_TYPE=int8\n'
    printf 'WHISPER_THREADS=2\n'
    printf 'VEXA_SSO_SECRET=ci-vexa-sso-secret-with-enough-length\n'
    printf 'ODOO_DATABASE=student_society\n'
    printf 'ODOO_SSO_SECRET=ci-odoo-sso-secret-with-enough-length\n'
    printf 'CADDY_IMAGE=caddy:2.11.4-alpine\n'
    printf 'UPTIME_KUMA_IMAGE=louislam/uptime-kuma:2\n'
  } > "$target"
}

validate_service() {
  local service="$1"
  local workdir="$TMP_DIR/$service"

  mkdir -p "$workdir"
  cp "$ROOT/$service/docker-compose.yml" "$workdir/docker-compose.yml"
  write_env "$workdir/.env"

  case "$service" in
    caddy)
      cp "$ROOT/caddy/Caddyfile.j2" "$workdir/Caddyfile"
      ;;
    n8n)
      cp "$ROOT/n8n/authentik-sso-hook.js" "$workdir/authentik-sso-hook.js"
      ;;
    vexa)
      cp "$ROOT/vexa/sso-bridge.py" "$workdir/sso-bridge.py"
      ;;
    odoo)
      mkdir -p "$workdir/config" "$workdir/addons"
      ;;
  esac

  docker compose --project-directory "$workdir" -f "$workdir/docker-compose.yml" --env-file "$workdir/.env" config --quiet
}

for service in authentik n8n vexa odoo uptime-kuma caddy; do
  validate_service "$service"
done

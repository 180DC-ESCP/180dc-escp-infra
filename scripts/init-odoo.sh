#!/usr/bin/env bash
set -euo pipefail

LIVE_ROOT="/opt/180dc"
COMPOSE="$LIVE_ROOT/apps/odoo/docker-compose.yml"
ENV_FILE="$LIVE_ROOT/apps/odoo/.env"

if [ "$(id -u)" -ne 0 ]; then
  echo "init-odoo.sh must run as root" >&2
  exit 1
fi

if [ ! -f "$COMPOSE" ] || [ ! -f "$ENV_FILE" ]; then
  echo "Odoo compose or env file is missing under $LIVE_ROOT/apps/odoo" >&2
  exit 1
fi

docker compose -f "$COMPOSE" --env-file "$ENV_FILE" up -d db
docker compose -f "$COMPOSE" --env-file "$ENV_FILE" run --rm init
docker compose -f "$COMPOSE" --env-file "$ENV_FILE" up -d odoo

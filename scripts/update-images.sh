#!/usr/bin/env bash
set -euo pipefail

for compose in \
  /opt/180dc/authentik/docker-compose.yml \
  /opt/180dc/apps/n8n/docker-compose.yml \
  /opt/180dc/caddy/docker-compose.yml
do
  docker compose -f "$compose" pull
done

docker compose -f /opt/180dc/authentik/docker-compose.yml up -d --remove-orphans
docker compose -f /opt/180dc/apps/n8n/docker-compose.yml up -d --remove-orphans
docker compose -f /opt/180dc/caddy/docker-compose.yml up -d --remove-orphans


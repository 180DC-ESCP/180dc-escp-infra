#!/usr/bin/env bash
set -euo pipefail

out="${1:-authentik/exported-blueprint.yaml}"
ssh_host="${SSH_HOST:-180dc}"

ssh -o ProxyJump=none "$ssh_host" \
  'cd /opt/180dc/authentik && docker compose exec -T worker ak export_blueprint' > "$out"

echo "exported $out"


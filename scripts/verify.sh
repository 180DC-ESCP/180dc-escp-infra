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

docker ps --format '{{.Names}} {{.Status}}' | sort

for url in \
  "https://login.${BASE_DOMAIN}/" \
  "https://n8n.${BASE_DOMAIN}/" \
  "https://hooks.${BASE_DOMAIN}/webhook/__verify_public_hooks__" \
  "https://vexa.${BASE_DOMAIN}/" \
  "https://vexa-api.${BASE_DOMAIN}/admin/users" \
  "https://odoo.${BASE_DOMAIN}/"
do
  code=""
  for attempt in 1 2 3 4 5; do
    if code="$(curl -k -s -o /dev/null -w '%{http_code}' "$url")"; then
      break
    fi
    echo "retrying $url after curl failure ($attempt/5)" >&2
    sleep 5
  done
  if [ -z "$code" ]; then
    echo "curl failed for $url" >&2
    exit 1
  fi
  case "$url:$code" in
    *login*:302|*n8n*:302|*hooks*:404|*vexa.180dc*:302|*vexa-api*:403|*odoo*:302)
      echo "ok $code $url"
      ;;
    *)
      echo "unexpected HTTP $code for $url" >&2
      exit 1
      ;;
  esac
done

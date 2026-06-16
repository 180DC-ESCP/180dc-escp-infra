#!/usr/bin/env bash
set -euo pipefail

docker ps --format '{{.Names}} {{.Status}}' | sort

for url in \
  https://login.180dc-escp.org/ \
  https://n8n.180dc-escp.org/ \
  https://hooks.180dc-escp.org/webhook/__verify_public_hooks__ \
  https://vexa.180dc-escp.org/ \
  https://vexa-api.180dc-escp.org/admin/users \
  https://odoo.180dc-escp.org/
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
    *login.180dc-escp.org*:302|*n8n.180dc-escp.org*:302|*hooks.180dc-escp.org*:404|*vexa.180dc-escp.org*:302|*vexa-api.180dc-escp.org*:302|*odoo.180dc-escp.org*:302)
      echo "ok $code $url"
      ;;
    *)
      echo "unexpected HTTP $code for $url" >&2
      exit 1
      ;;
  esac
done

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ruby - "$ROOT/ansible/group_vars/all.yml" <<'RUBY' | while IFS= read -r image; do
require "yaml"

config = YAML.load_file(ARGV.fetch(0))
config.fetch("images").each_value do |image|
  puts image
end
RUBY
  if [[ "$image" == *":latest" ]]; then
    echo "Refusing floating latest image tag: $image" >&2
    exit 1
  fi
  echo "Checking image reference: $image"
  docker manifest inspect "$image" >/dev/null
done

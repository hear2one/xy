#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
OUT_DIR=$(mktemp -d)
export OUT_DIR
trap 'rm -rf "$OUT_DIR"' EXIT
for builder in .github/scripts/build-*.sh; do
  bash "$builder"
done
for script in "$OUT_DIR"/*.sh; do
  bash -n "$script"
  if grep -n '^@@include ' "$script"; then
    echo "Unresolved template in $script" >&2
    exit 1
  fi
done
bash tests/input-validation.sh
bash tests/geodata-update.sh
bash tests/cdn-download-options.sh
echo 'All installer builds, Bash syntax checks and input regression tests passed.'

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/src/03-xray-install.sh"

error() { return 1; }

expect_valid() {
  local input="$1" expected="$2" actual
  actual=$(normalize_xray_version_tag "$input")
  [[ "$actual" == "$expected" ]] || {
    echo "normalize_xray_version_tag $input: expected $expected, got $actual" >&2
    exit 1
  }
}

expect_invalid() {
  local input="$1"
  if normalize_xray_version_tag "$input" >/dev/null 2>&1; then
    echo "normalize_xray_version_tag unexpectedly accepted: $input" >&2
    exit 1
  fi
}

expect_valid '26.9.9' 'v26.9.9'
expect_valid 'v26.9.9' 'v26.9.9'
expect_valid 'v26.9.9-beta.1' 'v26.9.9-beta.1'
expect_invalid ''
expect_invalid 'latest'
expect_invalid 'v26.9'
expect_invalid 'v26.9.9/../../bad'
expect_invalid 'v26.9.9;id'

XRAY_VERSION_MODE=stable XRAY_VERSION= select_xray_version
[[ "$XRAY_SELECTED_MODE" == stable ]]

XRAY_VERSION_MODE=version XRAY_VERSION=26.9.9 select_xray_version
[[ "$XRAY_SELECTED_MODE" == version ]]
[[ "$XRAY_SELECTED_VERSION" == v26.9.9 ]]

if XRAY_VERSION_MODE=keep XRAY_VERSION= select_xray_version; then
  echo 'keep mode unexpectedly succeeded without an installed Xray binary' >&2
  exit 1
fi

echo 'Xray version selection validation tests passed.'

#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render() (
  export CDN_DOWNLOAD_IPV4="$1"
  source "$ROOT_DIR/src/common/cdn-download-options.sh"
  # Render the real template, without executing installation modules.
  set +u
  eval "cat <<EOF
$(cat "$ROOT_DIR/templates/client-config.txt.tmpl")
EOF"
)
normal=$(render false)
ipv4=$(render true)
[[ "$normal" != *ForceIPv4* ]]
[[ "$(printf '%s\n' "$ipv4" | grep -c ForceIPv4)" == 1 ]]
[[ "$(printf '%s\n' "$ipv4" | tail -1)" == *'%22security%22%3A%22tls%22%2C%22sockopt%22%3A%7B%22domainStrategy%22%3A%22ForceIPv4%22%7D%2C%22tlsSettings'* ]]
[[ "$(printf '%s\n' "$normal" | head -4)" == "$(printf '%s\n' "$ipv4" | head -4)" ]]
if render invalid >/dev/null 2>&1; then
  echo 'Invalid policy accepted' >&2
  exit 1
fi
echo 'Optional CDN download IPv4 template tests passed.'

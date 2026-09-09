#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/src/common/input-validation.sh"
for domain in example.com cdn.example.com xn--fiqs8s.example 127.0.0.1; do
  validate_domain "$domain" || { echo "Rejected valid host: $domain"; exit 1; }
done
for domain in '' . .. example..com -example.com example-.com example.com. 'example.com;'; do
  if validate_domain "$domain"; then
    echo "Accepted invalid host: $domain"; exit 1
  fi
done
[[ "$(normalize_proxy_origin 'Example.COM/path?q=1')" == https://example.com ]]
[[ "$(normalize_proxy_origin 'http://example.com:8080/path')" == http://example.com:8080 ]]
for origin in 'https://example.com;evil' 'https://example.com evil' 'https://user@example.com' 'ftp://example.com' 'https://example.com:0' 'https://example.com:65536' 'https://example.com:$port' $'https://example.com\n;evil'; do
  if normalize_proxy_origin "$origin" >/dev/null; then
    echo "Accepted unsafe origin: $origin"; exit 1
  fi
done
echo 'Input validation regression tests passed.'

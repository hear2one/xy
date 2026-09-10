#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

rawurlencode() { printf '%s' "$1"; }
format_uri_host() { printf '%s' "$1"; }

run_client_case() {
  local hopping="$1" expected_uri_port="$2"
  local case_dir="$TMP_DIR/$hopping"
  mkdir -p "$case_dir"
  USER_HOME="$case_dir"
  V2RAYN_FILE="$case_dir/client-config.txt"
  MIHOMO_FULL_FILE="$case_dir/full.yaml"
  MIHOMO_NODES_FILE="$case_dir/nodes.yaml"
  printf 'vless://existing#existing\n' > "$V2RAYN_FILE"
  for file in "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"; do
    cat > "$file" <<'EOF'
proxies:
  - name: existing
    type: direct
proxy-groups:
  - name: select
    type: select
    proxies: [existing]
EOF
  done

  BASE_SERVER=192.0.2.10
  REALITY_DOMAIN=reality.example.com
  HY2_PASSWORD=test_password
  HY2_PORT=20000
  HY2_PORT_SPEC="$expected_uri_port"
  HY2_HOP_ENABLED="$hopping"
  HY2_HOP_INTERVAL=45
  # shellcheck source=../extensions/hysteria2/03-client-config.sh
  source "$ROOT_DIR/extensions/hysteria2/03-client-config.sh"

  grep -Fq "@192.0.2.10:${expected_uri_port}/?sni=reality.example.com&insecure=0" "$V2RAYN_FILE"
  for file in "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"; do
    grep -Fq '    port: 20000' "$file"
    if [[ "$hopping" == true ]]; then
      grep -Fq '    ports: "20000-30000"' "$file"
      grep -Fq '    hop-interval: 45' "$file"
    else
      ! grep -Fq '    ports:' "$file"
      ! grep -Fq '    hop-interval:' "$file"
    fi
  done
}

run_client_case true 20000-30000
run_client_case false 20000

grep -Fq 'listen: :${HY2_PORT_SPEC}' "$ROOT_DIR/extensions/hysteria2/02-server-config.sh"
grep -Fq "'2.8.0'" "$ROOT_DIR/extensions/hysteria2/02-server-config.sh"

echo 'Hysteria2 fixed-port and port-hopping output tests passed.'

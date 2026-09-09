#!/usr/bin/env bash
# Run only the extracted updater, with network and service commands mocked.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR
awk "/^cat > .*<<'UPDATEREOF'/ { capture=1; next } /^UPDATEREOF$/ { capture=0 } capture" \
  "$ROOT_DIR/src/08-server-config.sh" | \
  sed "s|/usr/local/share/xray|$TEST_DIR/assets|g" > "$TEST_DIR/update.sh"
bash -n "$TEST_DIR/update.sh"
curl() {
  if [[ "$*" == *api.github.com* ]]; then
    echo '{"tag_name": "test-release"}'
  else
    local output="${@: -1}"
    printf 'candidate protobuf fixture' > "$output"
  fi
}
xray() {
  [[ -s "$XRAY_LOCATION_ASSET/geoip.dat" && -s "$XRAY_LOCATION_ASSET/geosite.dat" ]] || return 1
  [[ "$CASE" != invalid ]]
}
command() {
  if [[ "$*" == '-v systemctl' ]]; then
    [[ "$SERVICE" == systemd ]]
  else
    builtin command "$@"
  fi
}
systemctl() {
  echo restart >> "$TEST_DIR/restarts"
  if [[ "$CASE" == restart_failure && ! -f "$TEST_DIR/failed-once" ]]; then
    touch "$TEST_DIR/failed-once"
    return 1
  fi
}
rc-service() { systemctl "$@"; }
export -f curl xray command systemctl rc-service
for SERVICE in systemd openrc; do
  for CASE in success invalid restart_failure; do
    export SERVICE CASE
    mkdir -p "$TEST_DIR/assets"
    printf 'old geoip' > "$TEST_DIR/assets/geoip.dat"
    printf 'old geosite' > "$TEST_DIR/assets/geosite.dat"
    rm -f "$TEST_DIR/restarts" "$TEST_DIR/failed-once"
    status=0
    bash "$TEST_DIR/update.sh" > "$TEST_DIR/output" 2>&1 || status=$?
    if [[ "$CASE" == success ]]; then
      [[ "$status" == 0 ]]
      [[ "$(cat "$TEST_DIR/assets/geoip.dat")" == 'candidate protobuf fixture' ]]
      [[ "$(cat "$TEST_DIR/assets/geosite.dat")" == 'candidate protobuf fixture' ]]
    else
      [[ "$status" != 0 ]]
      [[ "$(cat "$TEST_DIR/assets/geoip.dat")" == 'old geoip' ]]
      [[ "$(cat "$TEST_DIR/assets/geosite.dat")" == 'old geosite' ]]
      if [[ "$CASE" == invalid ]]; then
        [[ ! -f "$TEST_DIR/restarts" ]]
      else
        [[ "$(wc -l < "$TEST_DIR/restarts")" -eq 2 ]]
      fi
    fi
  done
done
echo 'Geodata success, invalid-data and rollback tests passed for systemd and OpenRC.'

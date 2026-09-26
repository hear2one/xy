#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/src/common/subscription-check.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
printf 'subscription content\n' > "$TEST_DIR/expected"
REALITY_DOMAIN=example.invalid
warn() { printf '%s\n' "$*"; }
error() { printf '%s\n' "$*"; exit 1; }
sleep() { :; }
curl() {
  [[ "$1" == --disable && "$2" == --noproxy && "$3" == '*' ]] || exit 90
  local output="" url="" arg
  while (( $# )); do
    case "$1" in
      --output) output="$2"; shift ;;
      https://*) url="$1" ;;
    esac
    shift
  done
  if [[ "$url" == *:8003/* ]]; then
    if [[ "$scenario" == refused ]]; then return 7; fi
    cp "$TEST_DIR/expected" "$output"
    return 0
  fi
  calls=$((calls + 1))
  case "$scenario" in
    delayed) (( calls > 2 )) || return 7 ;;
    refused|backend_only) return 7 ;;
    mismatch) printf 'wrong content' > "$output"; return 0 ;;
    partial) cp "$TEST_DIR/expected" "$output"; return 18 ;;
  esac
  cp "$TEST_DIR/expected" "$output"
}
calls=0 scenario=delayed
check_subscription /sub/test/v2rayn.txt "$TEST_DIR/expected"
[[ "$calls" == 3 ]]
for scenario in refused backend_only mismatch partial; do
  calls=0
  if (check_subscription /sub/test/v2rayn.txt "$TEST_DIR/expected") > "$TEST_DIR/log"; then
    echo "False success: $scenario" >&2; exit 1
  fi
  grep -Fq '已重试 5 次' "$TEST_DIR/log"
  if [[ "$scenario" == backend_only ]]; then
    grep -Fq 'Nginx 8003 订阅正常' "$TEST_DIR/log"
  fi
done
echo 'Subscription retries, proxy bypass, mismatch and backend diagnostics passed.'

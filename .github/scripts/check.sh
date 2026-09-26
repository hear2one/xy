#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
OUT_DIR=$(mktemp -d)
export OUT_DIR
trap 'rm -rf "$OUT_DIR"' EXIT

EXPECTED_INSTALLERS=(
  add-dual-cdn.sh
  add-dual-ip.sh
  add-hysteria2.sh
  add-quic.sh
  add-xhttp-reality.sh
  install.sh
  install-xhttp-reality.sh
  install-xpadding.sh
)
mapfile -t expected_installers < <(printf '%s\n' "${EXPECTED_INSTALLERS[@]}" | sort)

for builder in .github/scripts/build-*.sh; do
  bash "$builder"
done

# Keep the source builders, committed artifacts and README rolling-Release
# downloads on one exact manifest. The main-latest workflow refreshes those
# assets after every relevant main-branch update.
mapfile -t built_installers < <(find "$OUT_DIR" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | sort)
mapfile -t committed_installers < <(find "$ROOT_DIR/dist" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | sort)
if [[ "${built_installers[*]}" != "${expected_installers[*]}" ]]; then
  printf 'Unexpected built installer manifest:\n  %s\n' "${built_installers[*]}" >&2
  exit 1
fi
if [[ "${committed_installers[*]}" != "${expected_installers[*]}" ]]; then
  printf 'Unexpected committed installer manifest:\n  %s\n' "${committed_installers[*]}" >&2
  exit 1
fi
for installer in "${EXPECTED_INSTALLERS[@]}"; do
  grep -Fq "releases/download/main-latest/${installer}" README.md || {
    echo "README is missing the main-latest download command for ${installer}" >&2
    exit 1
  }
done
while IFS= read -r local_link; do
  [[ -e "$ROOT_DIR/$local_link" ]] || {
    echo "README contains a broken local link: $local_link" >&2
    exit 1
  }
done < <(grep -oE '\]\(\./[^)#]+' README.md | sed 's/^](\.\///' | sort -u)

for script in "$OUT_DIR"/*.sh; do
  bash -n "$script"
  if grep -n '^@@include ' "$script"; then
    echo "Unresolved template in $script" >&2
    exit 1
  fi
done

# The repository exposes runnable installers directly under dist/. Keep the
# committed artifacts byte-for-byte identical to a clean source build.
for script in "$OUT_DIR"/*.sh; do
  committed="$ROOT_DIR/dist/$(basename "$script")"
  [[ -f "$committed" ]] || {
    echo "Missing committed installer: $committed" >&2
    exit 1
  }
  cmp -s "$script" "$committed" || {
    echo "Stale committed installer: $committed" >&2
    exit 1
  }
done

for installer in install.sh install-xpadding.sh; do
  script="$OUT_DIR/$installer"
  grep -Fq 'NGINX_VER="1.30.5"' "$script"
  grep -Fq 'NGINX_SHA256="6c20565aa2325cb82216ae804f4a4ff1875179014759a381c42ddc8e11c4906d"' "$script"
  grep -Fq 'listen       127.0.0.1:8003 ssl;' "$script"
  grep -Fq 'chmod 600 /usr/local/etc/xray/config.json' "$script"
  grep -Fq 'geosite:category-ads-all' "$script"
  grep -Fq '"minClientVer": "26.3.27"' "$script"
done
grep -Fq '"minClientVer": "26.3.27"' "$OUT_DIR/install-xhttp-reality.sh"
grep -Fq '"minClientVer": "26.3.27"' "$OUT_DIR/add-xhttp-reality.sh"
bash tests/input-validation.sh
bash tests/geodata-update.sh
bash tests/cdn-download-options.sh
bash tests/hysteria2-port-hopping.sh
bash tests/xray-version-selection.sh
bash tests/subscription-check.sh
echo 'All installer builds, Bash syntax checks and input regression tests passed.'

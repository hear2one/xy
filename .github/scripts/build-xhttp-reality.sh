#!/usr/bin/env bash
# ==================================================
# 构建无域名单节点版: dist/install-xhttp-reality.sh
# VLESS-XHTTP-REALITY 直连（借用第三方网站 TLS，无需自己域名/证书/CDN）
# ==================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 复用主链通用模块 + 无域名专用模块
COMMON_MODULES=(
  src/01-env.sh
  src/02-os-service.sh
  src/03-xray-install.sh
)
NODOMAIN_MODULES=(
  src/nodomain/04-input.sh
  src/nodomain/05-env-install.sh
  src/nodomain/06-config.sh
  src/nodomain/07-service.sh
  src/nodomain/08-output.sh
)

append_with_includes() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == @@include\ * ]]; then
      append_with_includes "$ROOT_DIR/${line#@@include }"
    else
      printf '%s\n' "$line"
    fi
  done < "$1"
}

OUT_FILE="${OUT_DIR:-$ROOT_DIR/dist}/install-xhttp-reality.sh"
mkdir -p "$(dirname "$OUT_FILE")"

cat > "$OUT_FILE" <<'SCRIPTHEADER'
#!/bin/bash
set -e
SCRIPTHEADER

for module in "${COMMON_MODULES[@]}"; do
  append_with_includes "$ROOT_DIR/$module" >> "$OUT_FILE"
  if [[ "$module" == "src/01-env.sh" ]]; then
    cat >> "$OUT_FILE" <<'PROFILE'
# ==================================================
# 功能开关：无域名单节点版（VLESS-XHTTP-REALITY）
# ==================================================

FEATURE_XPADDING=false
FEATURE_CDN_ECH=false
CDN_ECH_ENABLED=false
CDN_ECH_QUERY=""
GEODATA_AUTO_UPDATE=false
PROFILE
  fi
done

for module in "${NODOMAIN_MODULES[@]}"; do
  append_with_includes "$ROOT_DIR/$module" >> "$OUT_FILE"
done

chmod +x "$OUT_FILE"
echo "Generated $OUT_FILE"

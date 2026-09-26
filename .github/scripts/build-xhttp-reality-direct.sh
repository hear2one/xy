#!/usr/bin/env bash
# ==================================================
# 构建扩展: dist/add-xhttp-reality.sh
# 在已部署 Yulinanami 全家桶上追加 VLESS-XHTTP-REALITY 借证书直连节点(新端口)
# 并更新本地客户端配置 + 订阅(5 节点 -> 6 节点)
# ==================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MODULES=(
  extensions/xhttp-reality-direct/00-env-utils.sh
  extensions/xhttp-reality-direct/01-read-existing.sh
  extensions/xhttp-reality-direct/02-server-config.sh
  extensions/xhttp-reality-direct/03-client-config.sh
  src/common/subscription-check.sh
  extensions/xhttp-reality-direct/04-subscription-output.sh
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

OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
OUTPUT="$OUT_DIR/add-xhttp-reality.sh"
mkdir -p "$OUT_DIR"

cat > "$OUTPUT" <<'SCRIPTHEADER'
#!/bin/bash
set -e
SCRIPTHEADER

for module in "${MODULES[@]}"; do
  append_with_includes "$ROOT_DIR/$module" >> "$OUTPUT"
  printf '\n' >> "$OUTPUT"
done
chmod +x "$OUTPUT"

echo "Generated $OUTPUT"

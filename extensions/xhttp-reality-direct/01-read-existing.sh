# ==================================================
# 读取已有部署参数 + 交互输入（VLESS-XHTTP-REALITY 借证书直连）
# ==================================================

STATE_FILE="/etc/xhttp-cdn/xhttp-reality-node.env"
XRAY_CONF="/usr/local/etc/xray/config.json"
command -v xray >/dev/null 2>&1 || error "未找到 xray，请先运行主脚本"

echo -e "\n${CYAN}[+] 追加扩展模式：VLESS-XHTTP-REALITY 借证书直连（新端口，不需要自己的域名）${NC}\n"
echo -e "${YELLOW}[+] 说明${NC}"
echo "  1. 需先成功运行主脚本（install.sh / install-xpadding.sh）"
echo "  2. 主 443 的 Reality 入站 target 已固定指向自己的 Nginx（承担 CDN 回源/回落），"
echo "     一个入站只能有一个 target，所以借第三方证书的节点必须在独立端口（默认 8443）"
echo "  3. 新节点实时借用第三方网站的 TLS 握手与证书外观（偷 TLS），零证书、零 CF 依赖"
echo "  4. 现有 5 个节点与订阅不受影响，追加后订阅变为 6 节点"
echo ""

find_client_files
info "读取已有客户端配置: $USER_HOME"

BASE_LINE=$(grep -F '#xhttp%2BReality%20%E4%B8%8A%E4%B8%8B%E8%A1%8C%E4%B8%8D%E5%88%86%E7%A6%BB' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
[[ -n "$BASE_LINE" ]] || error "未找到 xhttp+Reality 上下行不分离节点，无法自动读取参数"

BASE_SERVER=$(strip_ipv6_brackets "$(extract_uri_server "$BASE_LINE")")
XHTTP_PATH=$(get_query_param "$BASE_LINE" "path" || true)
REALITY_DOMAIN=$(get_query_param "$BASE_LINE" "sni" || true)
VLESSENC_ENCRYPTION=$(get_query_param "$BASE_LINE" "encryption" || true)

CDN_LINE=$(grep -F '#xhttp%2BTLS%2BH2' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
DEFAULT_CDN_DOMAIN=""
if [[ -n "$CDN_LINE" ]]; then
  DEFAULT_CDN_DOMAIN=$(get_query_param "$CDN_LINE" "host" || true)
  [[ -n "$DEFAULT_CDN_DOMAIN" ]] || DEFAULT_CDN_DOMAIN=$(get_query_param "$CDN_LINE" "sni" || true)
fi

[[ -n "$BASE_SERVER" ]] || error "读取 VPS 地址失败"
[[ -n "$XHTTP_PATH" ]] || error "读取 XHTTP Path 失败"
[[ -n "$REALITY_DOMAIN" ]] || error "读取 Reality 域名失败"
[[ -n "$VLESSENC_ENCRYPTION" ]] || error "读取 VLESS Encryption 失败（主部署 xhttp 节点未启用？）"

[[ -f "$XRAY_CONF" ]] || error "未找到 $XRAY_CONF，请先运行主脚本"
command -v python3 >/dev/null 2>&1 || error "未找到 python3，请先安装（apt install python3 / apk add python3）"

install -d -m 700 /etc/xhttp-cdn

# 重复运行：读取上次参数直接重建（幂等），不再提问
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  info "检测到已添加过借证书直连节点（$(basename "$STATE_FILE")），使用原参数重建："
  info "端口 $XRAY_PORT / 借用 $TARGET_HOST / UUID ${UUID3:0:8}..."
else
  read -rp "监听端口 [默认 8443]: " XRAY_PORT
  XRAY_PORT=${XRAY_PORT:-8443}
  [[ "$XRAY_PORT" =~ ^[0-9]{1,5}$ && "$XRAY_PORT" -ge 1 && "$XRAY_PORT" -le 65535 ]] || error "端口格式无效: $XRAY_PORT"

  # 已在 xray config 里（如 443/8001）或本机在监听 → 拒绝
  if python3 - "$XRAY_CONF" "$XRAY_PORT" <<'PYEOF'
import json, os, sys
cfg = json.load(open(sys.argv[1]))
port = int(sys.argv[2])
sys.exit(0 if any(ib.get("port") == port for ib in cfg.get("inbounds", [])) else 1)
PYEOF
  then
    error "端口 ${XRAY_PORT} 已存在于 xray 配置的 inbounds 中（主部署占用），请换一个端口"
  fi
  if (ss -Hltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE "[:.]${XRAY_PORT}[[:space:]]"; then
    error "端口 ${XRAY_PORT} 已被本机其他服务监听，请换一个端口"
  fi

  echo -e "${YELLOW}[+] 借用站点选择建议${NC}"
  echo "  - 优先与 VPS 同国/同 ASN 的海外大站，支持 TLS 1.3"
  echo "  - 避开套 Cloudflare/Cloudfront 的站点（探测流量会变成 CDN 端口转发，易被滥用）"
  echo "  - 避开烂大街默认站（apple/microsoft/google 等，易被特征库识别）"
  echo "  - 实测候选：www.archlinux.org（完美）、www.debian.org；可用本地 SNIProbe 自选"
  echo ""
  read -rp "借用 TLS 的网站域名（不带 https://，默认 www.archlinux.org）: " TARGET_HOST
  TARGET_HOST=${TARGET_HOST:-www.archlinux.org}
  [[ "$TARGET_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*\.)+[A-Za-z]{2,}$ ]] || error "域名格式无效: $TARGET_HOST"
  [[ "$TARGET_HOST" != "$REALITY_DOMAIN" ]] || error "借用站不能是自己主部署的 Reality 域名"
  if [[ -n "$DEFAULT_CDN_DOMAIN" ]]; then
    [[ "$TARGET_HOST" != "$DEFAULT_CDN_DOMAIN" ]] || error "借用站不能是 CDN 域名"
  fi
  if grep -Eiq '(^|\.)(cloudflare|cloudfront|fastly|akamai|incapsula|apple|microsoft|google|twitter|facebook)\.(com|net|org|io)$' <<< "$TARGET_HOST"; then
    echo -e "${YELLOW}[WARN]${NC} 该域名疑似知名 CDN / 烂大街默认站"
    read -rp "仍要使用 $TARGET_HOST 吗？[y/N]: "
    [[ "${REPLY,,}" == "y" ]] || error "已取消，请换一个站点重跑"
  fi

  # 生成独立参数（与主部署的 reality 密钥/UUID 完全隔离）
  UUID3=$(xray uuid)
  KEY_OUTPUT3=$(xray x25519 2>&1)
  PRIVATE_KEY3=$(echo "$KEY_OUTPUT3" | awk 'tolower($0) ~ /private/ { print $NF; exit }')
  PUBLIC_KEY3=$(echo "$KEY_OUTPUT3"  | awk 'tolower($0) ~ /public/  { print $NF; exit }')
  [[ -z "$UUID3" || -z "$PRIVATE_KEY3" || -z "$PUBLIC_KEY3" ]] && error "生成 UUID / x25519 密钥失败"
  SHORT_ID3=$(echo "$UUID3" | tr -d '-' | cut -c1-8)

  info "校验借用站点 ${TARGET_HOST}（xray tls ping，需支持 TLS 1.3 且可达）..."
  if ! PING_OUTPUT=$(xray tls ping "$TARGET_HOST" 2>&1); then
    echo -e "${YELLOW}[WARN]${NC} 借用站点校验未通过（目标不支持 TLS 1.3 / 不可达 / xray 过旧）："
    echo "$PING_OUTPUT" | head -5
    read -rp "仍要使用 $TARGET_HOST 继续吗？[y/N]: "
    [[ "${REPLY,,}" == "y" ]] || error "已取消。建议换一个站点后重跑"
  fi
fi

info "VPS 地址:    $BASE_SERVER"
info "XHTTP Path:  $XHTTP_PATH"
info "端口:        $XRAY_PORT"
info "借用站点:    $TARGET_HOST"
info "新 UUID:     ${UUID3:0:8}... (新 reality 密钥对已隔离生成)"
info "VLESS Enc:   与主部署同款（防中间人解密，decryption 从主 8001 入站读取）"
echo ""

# ==================================================
# 无域名模式：依赖 + Xray 安装 + 参数生成 + 借用站点 TLS 预检
# ==================================================

info "安装基础依赖与 Xray..."

if [[ "$OS_ID" == "alpine" ]]; then
  pkg_update
  pkg_install bash ca-certificates
  update-ca-certificates >/dev/null 2>&1 || true
fi
command -v curl >/dev/null 2>&1 || pkg_install curl

install_xray
export PATH="/usr/local/bin:$PATH"

info "生成参数..."
[[ -z "$UUID" ]] && UUID=$(xray uuid)

KEY_OUTPUT=$(xray x25519 2>&1)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk 'tolower($0) ~ /private/ { print $NF; exit }')
PUBLIC_KEY=$(echo "$KEY_OUTPUT"  | awk 'tolower($0) ~ /public/  { print $NF; exit }')
[[ -z "$PRIVATE_KEY" ]] && error "未能提取 Private Key，xray x25519 输出: $KEY_OUTPUT"
[[ -z "$PUBLIC_KEY" ]]  && error "未能提取 Public Key，xray x25519 输出: $KEY_OUTPUT"

[[ -z "$XHTTP_PATH" ]] && XHTTP_PATH="/$(xray uuid | tr -d '-' | cut -c1-8)"
SHORT_ID=$(xray uuid | tr -d '-' | cut -c1-8)

info "生成 VLESS Encryption 密钥对（与全家桶同款，防中间人解密）..."
if ! VLESSENC_OUTPUT=$(xray vlessenc 2>&1) || ! grep -qi "encryption" <<< "$VLESSENC_OUTPUT"; then
  error "VLESS Encryption 密钥生成失败，请确保 Xray 版本支持 vlessenc。输出: $VLESSENC_OUTPUT"
fi
VLESSENC_ENCRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '/ML-KEM/{found=1} found && /"encryption"/{print $4; exit}')
VLESSENC_DECRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '/ML-KEM/{found=1} found && /"decryption"/{print $4; exit}')
[[ -z "$VLESSENC_ENCRYPTION" ]] && error "未能提取 VLESS Encryption Key，xray vlessenc 输出: $VLESSENC_OUTPUT"
[[ -z "$VLESSENC_DECRYPTION" ]] && error "未能提取 VLESS Decryption Key，xray vlessenc 输出: $VLESSENC_OUTPUT"

info "检测公网 IP..."
VPS_IP=$(curl -4 -s --max-time 5 ip.sb || true)
if [[ -z "$VPS_IP" ]]; then
  VPS_IP=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
fi
if [[ -z "$VPS_IP" ]]; then
  VPS_IP=$(curl -6 -s --max-time 5 ip.sb || true)
fi
if [[ -z "$VPS_IP" ]]; then
  VPS_IP=$(curl -6 -s --max-time 5 https://api6.ipify.org || true)
fi
[[ -z "$VPS_IP" ]] && error "无法自动获取本机公网 IP（ip.sb / ipify 均失败），请手动设置 VPS_IP 环境变量后重跑"
if [[ "$VPS_IP" == *:* ]]; then
  VPS_IP_URI="[${VPS_IP}]"
else
  VPS_IP_URI="${VPS_IP}"
fi

# 借用站点预检：官方工具 xray tls ping（校验 TLS1.3 / 后量子 / 可达性）
info "校验借用站点 ${TARGET_HOST}（xray tls ping，确认支持 TLS 1.3 且可达）..."
if PING_OUTPUT=$(xray tls ping "$TARGET_HOST" 2>&1); then
  info "借用站点校验通过"
else
  echo -e "${YELLOW}[WARN]${NC} 借用站点校验未通过。可能原因：目标不支持 TLS 1.3 / 不可达 / xray 版本过旧。"
  echo "校验输出："
  echo "$PING_OUTPUT" | head -5
  read -rp "仍要使用 $TARGET_HOST 继续吗？[y/N]: "
  [[ "${REPLY,,}" == "y" ]] || error "已取消。建议换一个站点（可用 SNIProbe 实测挑选）后重跑"
fi

info "UUID:        $UUID"
info "Private Key: $PRIVATE_KEY"
info "Public Key:  $PUBLIC_KEY"
info "Short ID:    $SHORT_ID"
info "Path:        $XHTTP_PATH"
info "VPS IP:      $VPS_IP"
echo ""

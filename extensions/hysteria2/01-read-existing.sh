# ==================================================
# 读取已有节点参数
# ==================================================

echo -e "\n${CYAN}[+] 添加扩展模式：Hysteria2 直连${NC}\n"
echo -e "${YELLOW}[+] 前置条件${NC}"
echo "  1. 已经成功运行主脚本"
echo "  2. Hysteria2 使用的 UDP 端口未被其他服务占用"
echo ""

find_client_files
info "读取已有客户端配置: $USER_HOME"

REALITY_LINE=$(grep -F '#reality%2Bvision' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
[[ -n "$REALITY_LINE" ]] || error "未找到 reality+vision 节点，无法自动读取参数"

BASE_SERVER=$(strip_ipv6_brackets "$(extract_uri_server "$REALITY_LINE")")
REALITY_DOMAIN=$(get_query_param "$REALITY_LINE" "sni" || true)
[[ -n "$BASE_SERVER" ]] || error "读取 VPS IP 失败"
[[ -n "$REALITY_DOMAIN" ]] || error "读取 Reality 域名失败"

if [[ -f /etc/hysteria/config.yaml ]]; then
  HY2_PASSWORD=$(sed -n 's/^[[:space:]]*password:[[:space:]]*//p' /etc/hysteria/config.yaml | head -n1)
fi

read -rp "是否启用 Hysteria2 UDP 端口跳跃 [y/N]: " HY2_HOP_REPLY
if [[ "${HY2_HOP_REPLY,,}" == "y" ]]; then
  HY2_HOP_ENABLED=true
  read -rp "请输入端口范围 [起始-结束] (默认 20000-50000): " HY2_PORT_SPEC
  HY2_PORT_SPEC=${HY2_PORT_SPEC:-20000-50000}
  if [[ ! "$HY2_PORT_SPEC" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    error "端口跳跃范围无效，请使用 起始-结束 格式"
  fi
  HY2_PORT=${BASH_REMATCH[1]}
  HY2_PORT_END=${BASH_REMATCH[2]}
  if (( HY2_PORT < 1 || HY2_PORT_END > 65535 || HY2_PORT >= HY2_PORT_END )); then
    error "端口跳跃范围无效，须满足 1 <= 起始端口 < 结束端口 <= 65535"
  fi
  read -rp "请输入跳跃间隔秒数 [5-3600] (默认 30): " HY2_HOP_INTERVAL
  HY2_HOP_INTERVAL=${HY2_HOP_INTERVAL:-30}
  if [[ ! "$HY2_HOP_INTERVAL" =~ ^[0-9]+$ ]] ||
     (( HY2_HOP_INTERVAL < 5 || HY2_HOP_INTERVAL > 3600 )); then
    error "跳跃间隔无效，请输入 5-3600 的整数秒"
  fi
else
  HY2_HOP_ENABLED=false
  read -rp "请输入 Hysteria2 UDP 端口 [1-65535] (默认 9443): " HY2_PORT
  HY2_PORT=${HY2_PORT:-9443}
  if [[ ! "$HY2_PORT" =~ ^[0-9]+$ ]] ||
     (( HY2_PORT < 1 || HY2_PORT > 65535 )); then
    error "Hysteria2 UDP 端口无效，请输入 1-65535 的整数"
  fi
  HY2_PORT_SPEC=$HY2_PORT
  HY2_HOP_INTERVAL=30
fi

# Even though Hysteria2 uses UDP, avoid reusing well-known service port
# numbers so firewall/security-group rules and future protocol changes remain
# unambiguous. Detect non-default SSH ports where possible.
SSH_PORTS="22"
DETECTED_SSH_PORTS=""
if command -v sshd >/dev/null 2>&1; then
  DETECTED_SSH_PORTS=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -nu | tr '\n' ' ' || true)
fi
if [[ -z "$DETECTED_SSH_PORTS" && -f /etc/ssh/sshd_config ]]; then
  DETECTED_SSH_PORTS=$(sed -nE 's/^[[:space:]]*Port[[:space:]]+([0-9]+).*/\1/pI' /etc/ssh/sshd_config | sort -nu | tr '\n' ' ' || true)
fi
[[ -n "$DETECTED_SSH_PORTS" ]] && SSH_PORTS="$DETECTED_SSH_PORTS"

HY2_PORT_END=${HY2_PORT_END:-$HY2_PORT}
for reserved_port in 80 443 8443 $SSH_PORTS; do
  [[ "$reserved_port" =~ ^[0-9]+$ ]] || continue
  if (( reserved_port >= HY2_PORT && reserved_port <= HY2_PORT_END )); then
    error "Hysteria2 端口 ${HY2_PORT_SPEC} 包含保留端口 ${reserved_port}（SSH/HTTP/HTTPS/8443），请重新选择"
  fi
done

if [[ -f /etc/nginx/nginx.conf ]]; then
  while IFS= read -r quic_port; do
    if (( quic_port >= HY2_PORT && quic_port <= HY2_PORT_END )); then
      error "UDP ${quic_port} 已被 XHTTP H3 使用，不能包含在 Hysteria2 端口范围 ${HY2_PORT_SPEC} 中"
    fi
  done < <(sed -nE 's/^[[:space:]]*listen[[:space:]]+([0-9]+)[[:space:]]+quic([[:space:]]|;).*/\1/p' /etc/nginx/nginx.conf)
fi

DEFAULT_HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -hex 16)}"
read -rp "请输入 Hysteria2 密码 [默认 ${DEFAULT_HY2_PASSWORD}]: " HY2_PASSWORD
HY2_PASSWORD=${HY2_PASSWORD:-$DEFAULT_HY2_PASSWORD}
[[ "$HY2_PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]] || error "Hysteria2 密码仅支持字母、数字与 . _ ~ -"

info "VPS IP:       $BASE_SERVER"
info "Reality 域名: $REALITY_DOMAIN"
if [[ "$HY2_HOP_ENABLED" == true ]]; then
  info "Hysteria2:   UDP ${HY2_PORT_SPEC}，每 ${HY2_HOP_INTERVAL} 秒跳跃"
else
  info "Hysteria2:   UDP $HY2_PORT"
fi
echo ""

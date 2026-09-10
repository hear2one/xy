# ==================================================
# Hysteria2 服务端
# ==================================================

command -v acme.sh >/dev/null 2>&1 || error "未找到 acme.sh，请先运行主脚本"
[[ -f /etc/ssl/private/fullchain.cer && -f /etc/ssl/private/private.key ]] || error "未找到证书文件，请先运行主脚本"

HYSTERIA_BIN="/usr/local/bin/hysteria"
HYSTERIA_CONF_DIR="/etc/hysteria"
HYSTERIA_CONF="${HYSTERIA_CONF_DIR}/config.yaml"
HYSTERIA_SERVICE="hysteria-server"

install_hysteria_binary() {
  local hy_tmp
  case "$(uname -m)" in
    x86_64|amd64) HY_ARCH="amd64" ;;
    aarch64|arm64) HY_ARCH="arm64" ;;
    armv7l|armv7) HY_ARCH="arm" ;;
    s390x) HY_ARCH="s390x" ;;
    *) error "不支持的 CPU 架构: $(uname -m)，无法安装 Hysteria2" ;;
  esac
  info "下载 Hysteria2 (linux-${HY_ARCH})..."
  hy_tmp=$(mktemp)
  curl -fsSL -o "$hy_tmp" \
    "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" \
    || { rm -f "$hy_tmp"; error "Hysteria2 下载失败"; }
  install -m 755 "$hy_tmp" "$HYSTERIA_BIN"
  rm -f "$hy_tmp"
}

if [[ ! -x "$HYSTERIA_BIN" ]]; then
  install_hysteria_binary
else
  info "检测到已安装 Hysteria2，跳过下载"
fi

if [[ "$HY2_HOP_ENABLED" == true ]]; then
  HY2_VERSION=$($HYSTERIA_BIN version 2>&1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/^v//')
  if [[ -z "$HY2_VERSION" ]] ||
     [[ "$(printf '%s\n' '2.8.0' "$HY2_VERSION" | sort -V | head -n1)" != "2.8.0" ]]; then
    warn "端口范围监听需要 Hysteria2 2.8.0+，正在更新（当前 ${HY2_VERSION:-未知}）"
    install_hysteria_binary
    HY2_VERSION=$($HYSTERIA_BIN version 2>&1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/^v//')
    [[ -n "$HY2_VERSION" ]] || error "无法确认 Hysteria2 版本"
    [[ "$(printf '%s\n' '2.8.0' "$HY2_VERSION" | sort -V | head -n1)" == "2.8.0" ]] ||
      error "Hysteria2 ${HY2_VERSION} 不支持内置端口范围监听，需要 2.8.0+"
  fi
  if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
    info "端口跳跃需要 nftables 或 iptables，正在安装 iptables..."
    pkg_install iptables
  fi
  command -v nft >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1 ||
    error "未找到 nftables/iptables，无法启用端口跳跃"
fi

install -d -m 755 "$HYSTERIA_CONF_DIR"
cat > "$HYSTERIA_CONF" <<EOF
listen: :${HY2_PORT_SPEC}

tls:
  cert: /etc/ssl/private/fullchain.cer
  key: /etc/ssl/private/private.key

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://127.0.0.1:8003
    rewriteHost: false
    insecure: true
EOF
chmod 600 "$HYSTERIA_CONF"

if [[ "$OS_ID" == "alpine" ]]; then
  cat > "/etc/init.d/${HYSTERIA_SERVICE}" <<'EOF'
#!/sbin/openrc-run

name="hysteria-server"
description="Hysteria2 Server"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria-server.pid"
output_log="/var/log/hysteria-server.log"
error_log="/var/log/hysteria-server.log"

depend() {
    need net
}
EOF
  chmod +x "/etc/init.d/${HYSTERIA_SERVICE}"
  rc-update add "$HYSTERIA_SERVICE" default >/dev/null 2>&1 || true
  HYSTERIA_RESTART_CMD="rc-service ${HYSTERIA_SERVICE} restart"
else
  cat > "/etc/systemd/system/${HYSTERIA_SERVICE}.service" <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=${HYSTERIA_BIN} server --config ${HYSTERIA_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$HYSTERIA_SERVICE" >/dev/null 2>&1 || true
  HYSTERIA_RESTART_CMD="systemctl restart ${HYSTERIA_SERVICE}"
fi

acme.sh --install-cert -d "$REALITY_DOMAIN" --ecc \
  --key-file /etc/ssl/private/private.key \
  --fullchain-file /etc/ssl/private/fullchain.cer \
  --reloadcmd "${HYSTERIA_RESTART_CMD}; ${NGINX_RESTART_CMD}"

service_restart "$HYSTERIA_SERVICE"
if [[ "$OS_ID" != "alpine" ]]; then
  sleep 1
  systemctl is-active --quiet "$HYSTERIA_SERVICE" || error "Hysteria2 启动失败，请检查 journalctl -u ${HYSTERIA_SERVICE}"
fi
info "Hysteria2 已监听 UDP ${HY2_PORT_SPEC}"

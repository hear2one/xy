#!/bin/bash
set -e
# ==================================================
# 基础输出与环境检测
# ==================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="$ID"
else
  error "无法识别当前系统发行版"
fi

case "$OS_ID" in
  debian|ubuntu|centos|rhel|almalinux|rocky|ol|amzn|fedora|opensuse*|sles|alpine) ;;
  *)
    error "不支持的发行版: $OS_ID，目前支持 Debian/Ubuntu/CentOS/RHEL/Fedora/openSUSE/SLES/Alpine"
    ;;
esac

if [[ "$OS_ID" == "alpine" ]]; then
  NGINX_RESTART_CMD="rc-service nginx restart"
else
  NGINX_RESTART_CMD="systemctl restart nginx"
fi

service_restart() {
  if [[ "$OS_ID" == "alpine" ]]; then
    rc-service "$1" restart || rc-service "$1" start
  else
    systemctl reset-failed "$1" >/dev/null 2>&1 || true
    systemctl restart "$1"
  fi
}

rawurlencode() {
  local string="$1"
  local encoded="" i char hex
  local LC_ALL=C

  for ((i = 0; i < ${#string}; i++)); do
    char="${string:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        encoded+="$char"
        ;;
      *)
        printf -v hex '%02X' "'$char"
        encoded+="%${hex: -2}"
        ;;
    esac
  done

  printf '%s' "$encoded"
}

get_query_param() {
  local line="$1"
  local key="$2"
  local query part
  local -a parts

  query="${line#*\?}"
  query="${query%%#*}"

  IFS='&' read -r -a parts <<< "$query"
  for part in "${parts[@]}"; do
    if [[ "${part%%=*}" == "$key" ]]; then
      printf '%s' "${part#*=}"
      return 0
    fi
  done
  return 1
}

extract_uri_server() {
  local server="${1#*@}"
  server="${server%%\?*}"
  printf '%s' "${server%:443}"
}

strip_ipv6_brackets() {
  local value="$1"
  value="${value#[}"
  value="${value%]}"
  printf '%s' "$value"
}

format_uri_host() {
  local value="$1"
  if [[ "$value" == *:* ]]; then
    printf '[%s]' "$value"
  else
    printf '%s' "$value"
  fi
}

find_client_files() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  else
    USER_HOME=$(getent passwd 1000 2>/dev/null | cut -d: -f6 || true)
  fi
  [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || USER_HOME="/root"

  V2RAYN_FILE="$USER_HOME/client-config.txt"
  MIHOMO_FULL_FILE="$USER_HOME/client-config-mihomo-full.yaml"
  MIHOMO_NODES_FILE="$USER_HOME/client-config-mihomo-nodes.yaml"

  [[ -f "$V2RAYN_FILE" ]] || error "未找到 $V2RAYN_FILE，请先运行主脚本"
  [[ -f "$MIHOMO_FULL_FILE" ]] || error "未找到 $MIHOMO_FULL_FILE，请先运行主脚本"
  [[ -f "$MIHOMO_NODES_FILE" ]] || error "未找到 $MIHOMO_NODES_FILE，请先运行主脚本"
}

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

# ==================================================
# 追加客户端节点
# ==================================================

NODE_HY2_NAME="hysteria2 直连"
NODE_HY2_TAG=$(rawurlencode "$NODE_HY2_NAME")

sed -i "/#${NODE_HY2_TAG}\$/d" "$V2RAYN_FILE"
printf '%s\n' "hysteria2://$(rawurlencode "$HY2_PASSWORD")@$(format_uri_host "$BASE_SERVER"):${HY2_PORT_SPEC}/?sni=${REALITY_DOMAIN}&insecure=0#${NODE_HY2_TAG}" >> "$V2RAYN_FILE"
chown "$(stat -c '%u:%g' "$USER_HOME")" "$V2RAYN_FILE"

update_mihomo_file() {
  local source_file="$1"
  local tmp_file

  tmp_file=$(mktemp)
  awk -v node_name="$NODE_HY2_NAME" \
      -v server="$BASE_SERVER" \
      -v port="$HY2_PORT" \
      -v ports="$HY2_PORT_SPEC" \
      -v hop_enabled="$HY2_HOP_ENABLED" \
      -v hop_interval="$HY2_HOP_INTERVAL" \
      -v password="$HY2_PASSWORD" \
      -v sni="$REALITY_DOMAIN" '
    skip && !(/^  - name: / || /^proxy-groups:/) { next }
    skip { skip=0 }
    $0 == "  - name: " node_name { skip=1; next }

    /^proxy-groups:/ {
      print "  - name: " node_name
      print "    type: hysteria2"
      print "    server: \"" server "\""
      print "    port: " port
      if (hop_enabled == "true") {
        print "    ports: \"" ports "\""
        print "    hop-interval: " hop_interval
      }
      print "    password: \"" password "\""
      print "    sni: " sni
      print "    alpn:"
      print "      - h3"
      print ""
      inserted=1
    }

    { print }

    END {
      if (!inserted) {
        print ""
        print "  - name: " node_name
        print "    type: hysteria2"
        print "    server: \"" server "\""
        print "    port: " port
        if (hop_enabled == "true") {
          print "    ports: \"" ports "\""
          print "    hop-interval: " hop_interval
        }
        print "    password: \"" password "\""
        print "    sni: " sni
        print "    alpn:"
        print "      - h3"
      }
    }
  ' "$source_file" > "$tmp_file"

  cat "$tmp_file" > "$source_file"
  rm -f "$tmp_file"
}

for target_file in "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"; do
  update_mihomo_file "$target_file"
done
chown "$(stat -c '%u:%g' "$USER_HOME")" "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"

# ==================================================
# 订阅文件与二维码输出
# ==================================================

update_subscriptions() {
  local token_file="/etc/xhttp-cdn/sub_token"
  [[ -f "$token_file" ]] || {
    warn "未找到订阅 token，仅更新本地客户端文件"
    return
  }

  local token sub_dir v2rayn_url mihomo_full_url mihomo_nodes_url
  token=$(tr -d '\r\n' < "$token_file")
  sub_dir="/usr/local/nginx/html/sub/${token}"
  v2rayn_url="https://${REALITY_DOMAIN}/sub/${token}/v2rayn.txt"
  mihomo_full_url="https://${REALITY_DOMAIN}/sub/${token}/mihomo-full.yaml"
  mihomo_nodes_url="https://${REALITY_DOMAIN}/sub/${token}/mihomo-nodes.yaml"

  install -d -m 755 "$sub_dir"
  cp "$V2RAYN_FILE" "$sub_dir/v2rayn-raw.txt"
  base64 "$V2RAYN_FILE" | tr -d '\n' > "$sub_dir/v2rayn.txt"
  cp "$MIHOMO_FULL_FILE" "$sub_dir/mihomo-full.yaml"
  cp "$MIHOMO_NODES_FILE" "$sub_dir/mihomo-nodes.yaml"

  check_subscription() {
    cmp -s "$2" <(curl -kfsS --resolve "${REALITY_DOMAIN}:443:127.0.0.1" \
      "https://${REALITY_DOMAIN}$1") ||
      error "订阅自检失败: $1"
  }

  check_subscription "/sub/${token}/v2rayn.txt" "$sub_dir/v2rayn.txt"
  check_subscription "/sub/${token}/mihomo-full.yaml" "$sub_dir/mihomo-full.yaml"
  check_subscription "/sub/${token}/mihomo-nodes.yaml" "$sub_dir/mihomo-nodes.yaml"

  cat > "$USER_HOME/subscription-links.txt" << SUBLINKEOF
V2RayN / Shadowrocket 订阅:
$v2rayn_url

Mihomo 完整分流订阅:
$mihomo_full_url

Mihomo 纯节点订阅:
$mihomo_nodes_url

二维码 PNG 文件:
V2RayN / Shadowrocket: $USER_HOME/subscription-v2rayn.png
Mihomo 完整分流: $USER_HOME/subscription-mihomo-full.png
Mihomo 纯节点: $USER_HOME/subscription-mihomo-nodes.png
SUBLINKEOF
  chown "$(stat -c '%u:%g' "$USER_HOME")" "$USER_HOME/subscription-links.txt"

  echo -e "${YELLOW}[+] 订阅链接（Ctrl Shift + C 复制）${NC}"
  echo "V2RayN / Shadowrocket: $v2rayn_url"
  echo "Mihomo 完整分流: $mihomo_full_url"
  echo "Mihomo 纯节点: $mihomo_nodes_url"
  info "订阅文件已更新: $sub_dir"

  if command -v qrencode >/dev/null 2>&1; then
    output_qr() {
      local label="$1" url="$2" file="$3"
      qrencode -o "$file" -s 8 -m 2 "$url"
      chown "$(stat -c '%u:%g' "$USER_HOME")" "$file"
      echo -e "${YELLOW}[+] ${label}${NC}"
      qrencode -t ANSIUTF8 -m 1 "$url"
    }
    output_qr "V2RayN / Shadowrocket" "$v2rayn_url" "$USER_HOME/subscription-v2rayn.png"
    output_qr "Mihomo 完整分流" "$mihomo_full_url" "$USER_HOME/subscription-mihomo-full.png"
    output_qr "Mihomo 纯节点" "$mihomo_nodes_url" "$USER_HOME/subscription-mihomo-nodes.png"
  else
    warn "未检测到 qrencode，已跳过订阅二维码输出"
  fi
}

update_subscriptions
info "客户端更新订阅后即可看到新节点"


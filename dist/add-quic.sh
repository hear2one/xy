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

urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/}"
  value="${value//$'\r'/}"
  printf '%s' "$value"
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

extract_uri_user() {
  local line="$1"
  line="${line#vless://}"
  printf '%s' "${line%%@*}"
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

echo -e "\n${CYAN}[+] 添加扩展模式：XHTTP H3 / H2-H3 上下行分离${NC}\n"
echo -e "${YELLOW}[+] 前置条件${NC}"
echo "  1. 已经成功运行主脚本"
echo "  2. Nginx 已启用 HTTP/3"
echo "  3. XHTTP H3 使用的 UDP 端口未被其他服务占用"
echo ""

find_client_files
info "读取已有客户端配置: $USER_HOME"

BASE_LINE=$(grep -F '#xhttp%2BReality%20%E4%B8%8A%E4%B8%8B%E8%A1%8C%E4%B8%8D%E5%88%86%E7%A6%BB' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
[[ -n "$BASE_LINE" ]] || error "未找到 xhttp+Reality 上下行不分离节点，无法自动读取参数"
CDN_LINE=$(grep -F '#xhttp%2BTLS%2BH2' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
[[ -n "$CDN_LINE" ]] || error "未找到 xhttp+TLS+H2 节点，无法自动读取参数"

BASE_SERVER=$(strip_ipv6_brackets "$(extract_uri_server "$BASE_LINE")")
UUID2=$(extract_uri_user "$BASE_LINE")
XHTTP_PATH=$(get_query_param "$BASE_LINE" "path" || true)
REALITY_DOMAIN=$(get_query_param "$BASE_LINE" "sni" || true)
CDN_DOMAIN=$(get_query_param "$CDN_LINE" "host" || true)
ECH_PARAM=$(get_query_param "$CDN_LINE" "ech" || true)
VLESSENC_ENCRYPTION=$(get_query_param "$BASE_LINE" "encryption" || true)
XHTTP_EXTRA=$(get_query_param "$BASE_LINE" "extra" || true)

[[ -n "$UUID2" ]] || error "读取 UUID2 失败"
[[ -n "$BASE_SERVER" ]] || error "读取 VPS IP 失败"
[[ -n "$XHTTP_PATH" ]] || error "读取 XHTTP Path 失败"
[[ -n "$REALITY_DOMAIN" ]] || error "读取 Reality 域名失败"
[[ -n "$CDN_DOMAIN" ]] || error "读取 CDN 域名失败"
[[ -n "$VLESSENC_ENCRYPTION" ]] || error "读取 VLESS Encryption 失败"

if [[ -n "$ECH_PARAM" ]]; then
  read -rp "是否复用原 CDN 节点的 ECH [y/N]: "
  [[ "${REPLY,,}" == "y" ]] || ECH_PARAM=""
fi

if [[ -n "$XHTTP_EXTRA" ]]; then
  XHTTP_PADDING_KEY=$(sed -n 's/.*"xPaddingKey":[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/xray/config.json | head -n1)
  XHTTP_PADDING_HEADER=$(sed -n 's/.*"xPaddingHeader":[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/xray/config.json | head -n1)
  XHTTP_PADDING_PLACEMENT=$(sed -n 's/.*"xPaddingPlacement":[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/xray/config.json | head -n1)
  XHTTP_PADDING_METHOD=$(sed -n 's/.*"xPaddingMethod":[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/xray/config.json | head -n1)
  [[ -n "$XHTTP_PADDING_KEY" && -n "$XHTTP_PADDING_HEADER" &&
     -n "$XHTTP_PADDING_PLACEMENT" && -n "$XHTTP_PADDING_METHOD" ]] ||
    error "读取 xpadding 配置失败"
fi

read -rp "请输入 XHTTP H3 UDP 端口 [1-65535] (默认 443): " XHTTP_H3_PORT
XHTTP_H3_PORT=${XHTTP_H3_PORT:-443}
if [[ ! "$XHTTP_H3_PORT" =~ ^[0-9]+$ ]] ||
   (( XHTTP_H3_PORT < 1 || XHTTP_H3_PORT > 65535 )); then
  error "XHTTP H3 UDP 端口无效，请输入 1-65535 的整数"
fi
if [[ -f /etc/hysteria/config.yaml ]] &&
   grep -Eq "^[[:space:]]*listen:[[:space:]]*:${XHTTP_H3_PORT}[[:space:]]*$" /etc/hysteria/config.yaml; then
  error "UDP ${XHTTP_H3_PORT} 已被 Hysteria2 使用"
fi

info "VPS IP:       $BASE_SERVER"
info "CDN 域名:     $CDN_DOMAIN"
info "XHTTP Path:   $XHTTP_PATH"
info "XHTTP H3:     UDP $XHTTP_H3_PORT"
echo ""

# ==================================================
# Nginx XHTTP H3
# ==================================================

command -v nginx >/dev/null 2>&1 || error "未找到 nginx，请先运行主脚本"
command -v xray >/dev/null 2>&1 || error "未找到 xray，请先运行主脚本"
nginx -V 2>&1 | grep -q -- '--with-http_v3_module' || error "Nginx 未启用 HTTP/3 模块，请重新运行主脚本"

NGINX_CONF="/etc/nginx/nginx.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
[[ -f "$NGINX_CONF" ]] || error "未找到 $NGINX_CONF"
[[ -f "$XRAY_CONF" ]] || error "未找到 $XRAY_CONF"
[[ -f /etc/ssl/private/fullchain.cer && -f /etc/ssl/private/private.key ]] || error "未找到证书文件，请先运行主脚本"

sed -i \
  -e '/^[[:space:]]*# BEGIN quic xhttp$/,/^[[:space:]]*# END quic xhttp$/d' \
  "$NGINX_CONF"

grep -Eq "^[[:space:]]*server_name[[:space:]][[:space:]]*${CDN_DOMAIN};[[:space:]]*$" "$NGINX_CONF" ||
  error "未找到 CDN 域名 Nginx 配置"

sed -i "/^[[:space:]]*server_name[[:space:]][[:space:]]*${CDN_DOMAIN};[[:space:]]*$/a\\
        # BEGIN quic xhttp\\
        listen ${XHTTP_H3_PORT} quic reuseport;\\
        add_header Alt-Svc 'h3=\":${XHTTP_H3_PORT}\"; ma=86400' always;\\
        # END quic xhttp" "$NGINX_CONF"

nginx -t
xray -test -config "$XRAY_CONF"
service_restart nginx
info "XHTTP H3 已监听 Nginx UDP ${XHTTP_H3_PORT}"

# ==================================================
# 追加客户端节点
# ==================================================

NODE_XHTTP_H3_NAME="xhttp+TLS+H3"
NODE_H2_H3_NAME="上行 xhttp+TLS+H2 | 下行 xhttp+TLS+H3"
NODE_H3_H2_NAME="上行 xhttp+TLS+H3 | 下行 xhttp+TLS+H2"

BASE_SERVER_URI=$(format_uri_host "$BASE_SERVER")
XHTTP_PATH_ENC=$(rawurlencode "$XHTTP_PATH")

if [[ -n "$XHTTP_EXTRA" ]]; then
  BASE_EXTRA_JSON=$(urldecode "$XHTTP_EXTRA")
fi

build_download_extra() {
  local address="$1"
  local port="$2"
  local alpn="$3"
  local download

  download="\"downloadSettings\":{\"address\":\"$(json_escape "$address")\",\"port\":${port},\"network\":\"xhttp\",\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"$(json_escape "$CDN_DOMAIN")\",\"allowInsecure\":false,\"alpn\":[\"${alpn}\"],\"fingerprint\":\"chrome\"${ECH_PARAM:+,\"echConfigList\":\"$(json_escape "$(urldecode "$ECH_PARAM")")\"}},\"xhttpSettings\":{\"host\":\"$(json_escape "$CDN_DOMAIN")\",\"path\":\"$(json_escape "$XHTTP_PATH")\",\"mode\":\"auto\"${BASE_EXTRA_JSON:+,\"extra\":${BASE_EXTRA_JSON}}}}"

  if [[ -n "$BASE_EXTRA_JSON" ]]; then
    rawurlencode "${BASE_EXTRA_JSON%\}},${download}}"
  else
    rawurlencode "{${download}}"
  fi
}

sed -i \
  -e "/#$(rawurlencode "$NODE_XHTTP_H3_NAME")\$/d" \
  -e "/#$(rawurlencode "$NODE_H2_H3_NAME")\$/d" \
  -e "/#$(rawurlencode "$NODE_H3_H2_NAME")\$/d" \
  "$V2RAYN_FILE"
printf '%s\n%s\n%s\n' \
  "vless://${UUID2}@${BASE_SERVER_URI}:${XHTTP_H3_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0${ECH_PARAM:+&ech=${ECH_PARAM}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH_ENC}&mode=auto${XHTTP_EXTRA:+&extra=${XHTTP_EXTRA}}#$(rawurlencode "$NODE_XHTTP_H3_NAME")" \
  "vless://${UUID2}@${CDN_DOMAIN}:443?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h2&insecure=0&allowInsecure=0${ECH_PARAM:+&ech=${ECH_PARAM}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH_ENC}&mode=auto&extra=$(build_download_extra "$BASE_SERVER" "$XHTTP_H3_PORT" "h3")#$(rawurlencode "$NODE_H2_H3_NAME")" \
  "vless://${UUID2}@${BASE_SERVER_URI}:${XHTTP_H3_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h3&insecure=0&allowInsecure=0${ECH_PARAM:+&ech=${ECH_PARAM}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH_ENC}&mode=auto&extra=$(build_download_extra "$CDN_DOMAIN" "443" "h2")#$(rawurlencode "$NODE_H3_H2_NAME")" >> "$V2RAYN_FILE"
chown "$(stat -c '%u:%g' "$USER_HOME")" "$V2RAYN_FILE"

write_xhttp_node() {
  local name="$1"
  local server="$2"
  local port="$3"
  local alpn="$4"
  local download_server="${5:-}"
  local download_port="${6:-}"
  local download_alpn="${7:-}"

  cat <<EOF
  - name: ${name}
    type: vless
    server: "${server}"
    port: ${port}
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    encryption: "${VLESSENC_ENCRYPTION}"
    network: xhttp
    alpn:
      - ${alpn}
    servername: ${CDN_DOMAIN}
    client-fingerprint: chrome
EOF

  if [[ -n "$ECH_PARAM" ]]; then
    cat <<'EOF'
    ech-opts:
      enable: true
      query-server-name: cloudflare-ech.com
EOF
  fi

  cat <<EOF
    xhttp-opts:
      host: ${CDN_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto
EOF

  if [[ -n "$XHTTP_EXTRA" ]]; then
    cat <<EOF
      x-padding-obfs-mode: true
      x-padding-key: "${XHTTP_PADDING_KEY}"
      x-padding-header: "${XHTTP_PADDING_HEADER}"
      x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
      x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
  fi

  cat <<'EOF'
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"
        h-keep-alive-period: 0
EOF

  if [[ -n "$download_server" ]]; then
    cat <<EOF
      download-settings:
        host: ${CDN_DOMAIN}
        path: ${XHTTP_PATH}
        server: "${download_server}"
        port: ${download_port}
        tls: true
        alpn:
          - ${download_alpn}
        servername: ${CDN_DOMAIN}
        client-fingerprint: chrome
EOF

    if [[ -n "$ECH_PARAM" ]]; then
      cat <<'EOF'
        ech-opts:
          enable: true
          query-server-name: cloudflare-ech.com
EOF
    fi

    if [[ -n "$XHTTP_EXTRA" ]]; then
      cat <<EOF
        x-padding-obfs-mode: true
        x-padding-key: "${XHTTP_PADDING_KEY}"
        x-padding-header: "${XHTTP_PADDING_HEADER}"
        x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
        x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
    fi

    cat <<'EOF'
        reuse-settings:
          max-concurrency: "16-32"
          c-max-reuse-times: "0"
          h-max-reusable-secs: "1800-3000"
          h-keep-alive-period: 0
EOF
  fi
}

build_quic_nodes_block() {
  write_xhttp_node "$NODE_XHTTP_H3_NAME" "$BASE_SERVER" "$XHTTP_H3_PORT" "h3"
  write_xhttp_node "$NODE_H2_H3_NAME" "$CDN_DOMAIN" "443" "h2" "$BASE_SERVER" "$XHTTP_H3_PORT" "h3"
  write_xhttp_node "$NODE_H3_H2_NAME" "$BASE_SERVER" "$XHTTP_H3_PORT" "h3" "$CDN_DOMAIN" "443" "h2"
}

update_mihomo_file() {
  local source_file="$1"
  local node_file
  local tmp_file

  node_file=$(mktemp)
  tmp_file=$(mktemp)
  build_quic_nodes_block > "$node_file"

  awk -v h3_name="$NODE_XHTTP_H3_NAME" \
      -v h2_h3_name="$NODE_H2_H3_NAME" \
      -v h3_h2_name="$NODE_H3_H2_NAME" \
      -v node_file="$node_file" '
    skip && !(/^  - name: / || /^proxy-groups:/) { next }
    skip { skip=0 }

    $0 == "  - name: " h3_name ||
    $0 == "  - name: " h2_h3_name ||
    $0 == "  - name: " h3_h2_name {
      skip=1
      next
    }

    /^proxy-groups:/ {
      while ((getline line < node_file) > 0) print line
      print ""
      inserted=1
    }

    { print }

    END {
      if (!inserted) {
        print ""
        while ((getline line < node_file) > 0) print line
      }
    }
  ' "$source_file" > "$tmp_file"

  cat "$tmp_file" > "$source_file"
  rm -f "$node_file" "$tmp_file"
}

for target_file in "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"; do
  update_mihomo_file "$target_file"
done
chown "$(stat -c '%u:%g' "$USER_HOME")" "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"

# Local end-to-end subscription check: Xray :443 -> Nginx :8003.
# A successful backend probe is diagnostic only, never a substitute for :443.
check_subscription() {
  local endpoint="$1" expected="$2" probe_dir attempt rc=0 reason=""
  probe_dir=$(mktemp -d) || error "无法创建订阅自检临时目录"
  for attempt in 1 2 3 4 5; do
    if curl --disable --noproxy '*' -kfsS --connect-timeout 3 --max-time 5 \
      --resolve "${REALITY_DOMAIN}:443:127.0.0.1" \
      --output "$probe_dir/body" "https://${REALITY_DOMAIN}${endpoint}" 2>"$probe_dir/error"; then
      if cmp -s "$expected" "$probe_dir/body"; then
        rm -rf "$probe_dir"
        return 0
      fi
      reason="443 已响应，但订阅内容与本地文件不一致"
    else
      rc=$?
      reason="本机 127.0.0.1:443 请求失败（curl 退出码 ${rc}）"
    fi
    [[ "$attempt" == 5 ]] || sleep 1
  done
  warn "$reason"
  if curl --disable --noproxy '*' -kfsS --connect-timeout 3 --max-time 5 \
    --resolve "${REALITY_DOMAIN}:8003:127.0.0.1" \
    --output "$probe_dir/backend" "https://${REALITY_DOMAIN}:8003${endpoint}" 2>"$probe_dir/error" &&
    cmp -s "$expected" "$probe_dir/backend"; then
    warn "Nginx 8003 订阅正常；请检查 Xray 443 监听、Reality target 和本机防火墙"
  else
    warn "Nginx 8003 后端也未通过；请检查 Nginx 状态、证书、/sub/ 路由及文件权限"
  fi
  warn "检查命令：ss -ltnp；systemctl status xray nginx --no-pager（Alpine：rc-service xray status / rc-service nginx status）"
  rm -rf "$probe_dir"
  error "订阅自检失败（已重试 5 次）；客户端文件已保留，请排查服务，勿为此直接重装或重新生成密钥"
}

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


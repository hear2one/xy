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
  NGINX_STOP_CMD="rc-service nginx stop"
  NGINX_START_CMD="rc-service nginx start"
  NGINX_RESTART_CMD="rc-service nginx restart"
else
  NGINX_STOP_CMD="systemctl stop nginx"
  NGINX_START_CMD="systemctl start nginx"
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

# Shared by generated installers; keep this file free of side effects.
validate_domain() {
  local domain="$1" label
  local -a labels
  [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *. ]] || return 1
  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

normalize_proxy_origin() {
  local url="$1" scheme authority host port
  [[ "$url" =~ [[:space:]] ]] && return 1
  [[ "$url" =~ ^https?:// ]] || url="https://${url}"
  [[ "$url" =~ ^(https?)://([^/?#]+)([/?#].*)?$ ]] || return 1
  scheme="${BASH_REMATCH[1]}"
  authority="${BASH_REMATCH[2]}"
  host="${authority%%:*}"
  validate_domain "$host" || return 1
  if [[ "$authority" == *:* ]]; then
    port="${authority#*:}"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  fi
  printf '%s://%s' "$scheme" "${authority,,}"
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

echo -e "\n${CYAN}[+] 添加扩展模式：上行 CDN-A | 下行 CDN-B${NC}\n"
echo -e "${YELLOW}[+] 前置条件${NC}"
echo "  1. 已经成功运行主脚本"
echo "  2. CDN-A / CDN-B 域名 DNS → 代理开启（橙色云朵）"
echo "  3. CDN-A / CDN-B 所在 Cloudflare 区域已开启 gRPC"
echo "  4. SSL/TLS 加密 → 完全（严格）"
echo ""

find_client_files
info "读取已有客户端配置: $USER_HOME"

BASE_LINE=$(grep -F '#xhttp%2BTLS%2BH2' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
[[ -n "$BASE_LINE" ]] || error "未找到 xhttp+TLS+H2 节点，无法自动派生 CDN-A 参数"

REALITY_LINE=$(grep -F '#reality%2Bvision' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
[[ -n "$REALITY_LINE" ]] || error "未找到 reality+vision 节点，无法读取 Reality 域名"

UUID2=$(extract_uri_user "$BASE_LINE")
DEFAULT_CDN_DOMAIN=$(get_query_param "$BASE_LINE" "host" || true)
[[ -n "$DEFAULT_CDN_DOMAIN" ]] || DEFAULT_CDN_DOMAIN=$(get_query_param "$BASE_LINE" "sni" || true)
[[ -n "$DEFAULT_CDN_DOMAIN" ]] || DEFAULT_CDN_DOMAIN=$(extract_uri_server "$BASE_LINE")
XHTTP_PATH=$(get_query_param "$BASE_LINE" "path" || true)
VLESSENC_ENCRYPTION=$(get_query_param "$BASE_LINE" "encryption" || true)
BASE_EXTRA_ENC=$(get_query_param "$BASE_LINE" "extra" || true)
ECH_PARAM=$(get_query_param "$BASE_LINE" "ech" || true)
REALITY_DOMAIN=$(get_query_param "$REALITY_LINE" "sni" || true)
VPS_SERVER=$(extract_uri_server "$REALITY_LINE")

[[ -n "$UUID2" ]] || error "读取 UUID2 失败"
[[ -n "$DEFAULT_CDN_DOMAIN" ]] || error "读取默认 CDN 域名失败"
[[ -n "$XHTTP_PATH" ]] || error "读取 XHTTP Path 失败"
[[ -n "$VLESSENC_ENCRYPTION" ]] || error "读取 VLESS Encryption 失败"
[[ -n "$REALITY_DOMAIN" ]] || error "读取 Reality 域名失败"
[[ -n "$VPS_SERVER" ]] || error "读取 VPS 地址失败"

if [[ -n "$ECH_PARAM" ]]; then
  read -rp "是否复用原 CDN 节点的 ECH [y/N]: "
  [[ "${REPLY,,}" == "y" ]] || ECH_PARAM=""
fi

[[ -f /etc/xhttp-cdn/fallback.env ]] || error "未找到主脚本回落配置，请重新运行主脚本"
# shellcheck disable=SC1090
. /etc/xhttp-cdn/fallback.env

[[ "$FALLBACK_MODE" == "proxy" || "$FALLBACK_MODE" == "static" ]] || error "主脚本回落方式无效，请重新运行主脚本"

read -rp "请输入 CDN-A 域名（上行，默认 ${DEFAULT_CDN_DOMAIN}）: " CDN_A
CDN_A=${CDN_A:-$DEFAULT_CDN_DOMAIN}
[[ -z "$CDN_A" ]] && error "CDN-A 域名不能为空"
[[ "$CDN_A" =~ ^[A-Za-z0-9.-]+$ && "$CDN_A" != "." && "$CDN_A" != ".." ]] || error "CDN-A 域名格式无效"
[[ "$CDN_A" != "$REALITY_DOMAIN" ]] || error "CDN-A 域名不能与 Reality 域名相同"

read -rp "请输入 CDN-B 域名（下行 CDN，如 cdn-b.example.com）: " CDN_B
[[ -z "$CDN_B" ]] && error "CDN-B 域名不能为空"
[[ "$CDN_B" =~ ^[A-Za-z0-9.-]+$ && "$CDN_B" != "." && "$CDN_B" != ".." ]] || error "CDN-B 域名格式无效"
[[ "$CDN_B" != "$REALITY_DOMAIN" ]] || error "CDN-B 域名不能与 Reality 域名相同"
if [[ "$CDN_B" == "$CDN_A" ]]; then
  warn "CDN-A 与 CDN-B 相同，将按同一域名处理"
fi

if [[ "$FALLBACK_MODE" == "proxy" ]]; then
  [[ -n "$CDN_FALLBACK_ORIGIN" && -n "$CDN_FALLBACK_HOST" ]] || error "主脚本 CDN 回落网站为空，请重新运行主脚本"

  if [[ "$CDN_A" == "$DEFAULT_CDN_DOMAIN" ]]; then
    CDN_A_FALLBACK_ORIGIN="$CDN_FALLBACK_ORIGIN"
    CDN_A_FALLBACK_HOST="$CDN_FALLBACK_HOST"
  else
    read -rp "请输入 ${CDN_A} 的回落网站: " CDN_A_FALLBACK_ORIGIN
    CDN_A_FALLBACK_ORIGIN=$(normalize_proxy_origin "$CDN_A_FALLBACK_ORIGIN") || error "CDN-A 回落网站格式无效"
    CDN_A_FALLBACK_HOST=${CDN_A_FALLBACK_ORIGIN#*://}
    [[ "$CDN_A_FALLBACK_ORIGIN" != "$REALITY_FALLBACK_ORIGIN" && "$CDN_A_FALLBACK_ORIGIN" != "$CDN_FALLBACK_ORIGIN" ]] || error "不同入口域名不能共用回落网站"
  fi

  if [[ "$CDN_B" == "$CDN_A" ]]; then
    CDN_B_FALLBACK_ORIGIN="$CDN_A_FALLBACK_ORIGIN"
    CDN_B_FALLBACK_HOST="$CDN_A_FALLBACK_HOST"
  elif [[ "$CDN_B" == "$DEFAULT_CDN_DOMAIN" ]]; then
    CDN_B_FALLBACK_ORIGIN="$CDN_FALLBACK_ORIGIN"
    CDN_B_FALLBACK_HOST="$CDN_FALLBACK_HOST"
  else
    read -rp "请输入 ${CDN_B} 的回落网站: " CDN_B_FALLBACK_ORIGIN
    CDN_B_FALLBACK_ORIGIN=$(normalize_proxy_origin "$CDN_B_FALLBACK_ORIGIN") || error "CDN-B 回落网站格式无效"
    CDN_B_FALLBACK_HOST=${CDN_B_FALLBACK_ORIGIN#*://}
    [[ "$CDN_B_FALLBACK_ORIGIN" != "$REALITY_FALLBACK_ORIGIN" && "$CDN_B_FALLBACK_ORIGIN" != "$CDN_FALLBACK_ORIGIN" ]] || error "不同入口域名不能共用回落网站"
    [[ "$CDN_B_FALLBACK_ORIGIN" != "$CDN_A_FALLBACK_ORIGIN" ]] || error "CDN-A 和 CDN-B 不能共用回落网站"
  fi
else
  prepare_static_site() {
    local domain="$1"
    mkdir -p "${STATIC_SITE_DIR}/${domain}"
    if [[ ! -f "${STATIC_SITE_DIR}/${domain}/index.html" ]]; then
      cat > "${STATIC_SITE_DIR}/${domain}/index.html" <<'INITIAL_HTML_EOF'
<!doctype html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>欢迎</title>
</head>
<body>
    <main>
        <h1>欢迎访问</h1>
        <p>网站正在准备中。</p>
    </main>
</body>
</html>
INITIAL_HTML_EOF
      sed -i \
        -e "s|<title>欢迎</title>|<title>${domain}</title>|" \
        -e "s|<h1>欢迎访问</h1>|<h1>${domain}</h1>|" \
        "${STATIC_SITE_DIR}/${domain}/index.html"
      chmod 644 "${STATIC_SITE_DIR}/${domain}/index.html"
    fi
    chown "$(stat -c '%u:%g' "$USER_HOME")" \
      "${STATIC_SITE_DIR}/${domain}" \
      "${STATIC_SITE_DIR}/${domain}/index.html"
  }

  prepare_static_site "$CDN_A"
  [[ "$CDN_B" == "$CDN_A" ]] || prepare_static_site "$CDN_B"
  echo "请将 dist 文件夹上传到 /var/www/"
  echo "CDN-A 页面：dist/${CDN_A}/index.html"
  echo "CDN-B 页面：dist/${CDN_B}/index.html"
  read -rp "确认各域名页面准备完成后按 Enter 继续: "
  [[ -f "${STATIC_SITE_DIR}/${CDN_A}/index.html" ]] || error "未找到 CDN-A 页面"
  [[ -f "${STATIC_SITE_DIR}/${CDN_B}/index.html" ]] || error "未找到 CDN-B 页面"
fi

info "Reality 域名: $REALITY_DOMAIN"
info "原 CDN 域名:  $DEFAULT_CDN_DOMAIN"
info "CDN-A 域名:   $CDN_A"
info "CDN-B 域名:   $CDN_B"
if [[ "$FALLBACK_MODE" == "proxy" ]]; then
  info "CDN-A 回落:   $CDN_A_FALLBACK_ORIGIN"
  info "CDN-B 回落:   $CDN_B_FALLBACK_ORIGIN"
fi
info "XHTTP Path:   $XHTTP_PATH"
echo ""

# ==================================================
# 证书与 Nginx
# ==================================================

command -v acme.sh >/dev/null 2>&1 || error "未找到 acme.sh，请先运行主脚本"
command -v nginx >/dev/null 2>&1 || error "未找到 nginx，请先运行主脚本"

ACME_CERT_HOME="/root/.acme.sh/${REALITY_DOMAIN}_ecc"
ACME_LISTEN_ARGS=()
[[ "$VPS_SERVER" == \[*\] ]] && ACME_LISTEN_ARGS=(--listen-v6)
NGINX_CONF="/etc/nginx/nginx.conf"
[[ -f "$NGINX_CONF" ]] || error "未找到 $NGINX_CONF"

DUAL_CDN_STATE_FILE="/etc/xhttp-cdn/dual-cdn-domains"
DUAL_IP_STATE_FILE="/etc/xhttp-cdn/dual-ip-domains"
install -d -m 700 /etc/xhttp-cdn

PREV_DUAL_CDN_DOMAINS=()
if [[ -f "$DUAL_CDN_STATE_FILE" ]]; then
  mapfile -t PREV_DUAL_CDN_DOMAINS < "$DUAL_CDN_STATE_FILE"
fi

CERT_DOMAINS=()
add_cert_domain() {
  if [[ -n "$1" && " ${CERT_DOMAINS[*]} " != *" $1 "* ]]; then
    CERT_DOMAINS+=("$1")
  fi
}

add_cert_domain "$REALITY_DOMAIN"
add_cert_domain "$DEFAULT_CDN_DOMAIN"
add_cert_domain "$CDN_A"
add_cert_domain "$CDN_B"
if [[ -f "$DUAL_IP_STATE_FILE" ]]; then
  while IFS= read -r domain; do
    add_cert_domain "$domain"
  done < "$DUAL_IP_STATE_FILE"
fi

ACME_DOMAIN_ARGS=()
for domain in "${CERT_DOMAINS[@]}"; do
  ACME_DOMAIN_ARGS+=(-d "$domain")
done

cert_has_all_domains() {
  [[ -f "$ACME_CERT_HOME/${REALITY_DOMAIN}.conf" ]] || return 1
  [[ -f "$ACME_CERT_HOME/fullchain.cer" ]] || return 1
  [[ -f "$ACME_CERT_HOME/${REALITY_DOMAIN}.key" ]] || return 1

  local cert_domains domain
  cert_domains=$(openssl x509 -in "$ACME_CERT_HOME/fullchain.cer" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://' || true)

  for domain in "${CERT_DOMAINS[@]}"; do
    grep -Fxq "$domain" <<< "$cert_domains" || return 1
  done
  return 0
}

if cert_has_all_domains; then
  info "检测到证书已包含所需域名，跳过重新签发"
else
  info "申请 / 更新包含 CDN-A、CDN-B 的证书..."
  if ! ISSUE_OUTPUT=$(acme.sh --issue "${ACME_DOMAIN_ARGS[@]}" \
      --standalone "${ACME_LISTEN_ARGS[@]}" --keylength ec-256 \
      --pre-hook "${NGINX_STOP_CMD} 2>/dev/null || true" \
      --post-hook "${NGINX_START_CMD} 2>/dev/null || true" 2>&1); then
    grep -Eqi 'Domains not changed|Skipping\. Next renewal time' <<< "$ISSUE_OUTPUT" || {
      echo "$ISSUE_OUTPUT"
      error "包含 CDN-A / CDN-B 的证书申请失败"
    }
  fi
  echo "$ISSUE_OUTPUT"
fi

info "安装证书..."
acme.sh --install-cert -d "$REALITY_DOMAIN" --ecc \
  --key-file /etc/ssl/private/private.key \
  --fullchain-file /etc/ssl/private/fullchain.cer \
  --reloadcmd "${NGINX_RESTART_CMD}"

append_cdn_block() {
  local domain="$1"
  local fallback_origin="$2"
  local fallback_host="$3"

  cat <<EOF
    server {
        listen       127.0.0.1:8003 ssl;
        http2        on;
        server_name  ${domain};

        ssl_certificate /etc/ssl/private/fullchain.cer;
        ssl_certificate_key /etc/ssl/private/private.key;

        location / {
EOF

  if [[ "$FALLBACK_MODE" == "static" ]]; then
    cat <<EOF
            root ${STATIC_SITE_DIR}/${domain};
            index index.html;
            try_files \$uri \$uri/ /index.html;
EOF
  else
    cat <<EOF
            proxy_pass ${fallback_origin};
            proxy_ssl_server_name on;
            proxy_ssl_name ${fallback_host};
            proxy_redirect http://${fallback_host}/ https://\$host/;
            proxy_redirect https://${fallback_host}/ https://\$host/;
            proxy_set_header Host ${fallback_host};
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
EOF
  fi

  cat <<EOF
        }

        location ${XHTTP_PATH} {
            grpc_pass 127.0.0.1:8001;
            grpc_set_header Host                  \$host;
            grpc_set_header X-Real-IP             \$real_client_ip;
            grpc_set_header Forwarded             \$proxy_add_forwarded;
            grpc_set_header X-Forwarded-For       \$proxy_add_x_forwarded_for;
            grpc_set_header X-Forwarded-Proto     \$scheme;
        }
    }
EOF
}

remove_nginx_server_block() {
  local domain="$1"
  local config="$2"
  local output
  output=$(mktemp)

  awk -v domain="$domain" '
    function count_braces(line, i, c) {
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
    }

    !in_server && /^[[:space:]]*server[[:space:]]*\{/ {
      in_server = 1
      depth = 0
      hit = 0
      block = $0 ORS
      count_braces($0)
      next
    }

    in_server {
      block = block $0 ORS
      if ($0 ~ /^[[:space:]]*server_name[[:space:]]/ && index($0, domain)) hit = 1
      count_braces($0)
      if (depth == 0) {
        if (!hit) printf "%s", block
        in_server = 0
        block = ""
      }
      next
    }

    { print }
  ' "$config" > "$output"
  cat "$output" > "$config"
  rm -f "$output"
}

tmp_nginx=$(mktemp)
cp "$NGINX_CONF" "$tmp_nginx"

for domain in "${PREV_DUAL_CDN_DOMAINS[@]}" "$CDN_A" "$CDN_B"; do
  [[ -n "$domain" && "$domain" != "$DEFAULT_CDN_DOMAIN" ]] || continue
  remove_nginx_server_block "$domain" "$tmp_nginx"
done

if [[ "$CDN_A" == "$CDN_B" && "$CDN_A" != "$DEFAULT_CDN_DOMAIN" ]]; then
  warn "CDN-A 与 CDN-B 域名相同，无法生成两个独立 server block，将只写入一个回落站"
fi

if [[ "$CDN_A" == "$DEFAULT_CDN_DOMAIN" ]]; then
  warn "CDN-A 与原 CDN 域名相同，将复用主脚本写入的 server block"
fi
if [[ "$CDN_B" == "$DEFAULT_CDN_DOMAIN" ]]; then
  warn "CDN-B 与原 CDN 域名相同，将复用主脚本写入的 server block"
fi

sed -i '$d' "$tmp_nginx"

if [[ "$CDN_A" != "$DEFAULT_CDN_DOMAIN" ]]; then
  append_cdn_block "$CDN_A" "$CDN_A_FALLBACK_ORIGIN" "$CDN_A_FALLBACK_HOST" >> "$tmp_nginx"
fi

if [[ "$CDN_B" != "$DEFAULT_CDN_DOMAIN" && "$CDN_B" != "$CDN_A" ]]; then
  append_cdn_block "$CDN_B" "$CDN_B_FALLBACK_ORIGIN" "$CDN_B_FALLBACK_HOST" >> "$tmp_nginx"
fi

echo "}" >> "$tmp_nginx"
cat "$tmp_nginx" > "$NGINX_CONF"
rm -f "$tmp_nginx"
info "已为 CDN-A / CDN-B 写入独立回落站"

: > "$DUAL_CDN_STATE_FILE"
if [[ "$CDN_A" != "$DEFAULT_CDN_DOMAIN" ]]; then
  echo "$CDN_A" >> "$DUAL_CDN_STATE_FILE"
fi
if [[ "$CDN_B" != "$DEFAULT_CDN_DOMAIN" && "$CDN_B" != "$CDN_A" ]]; then
  echo "$CDN_B" >> "$DUAL_CDN_STATE_FILE"
fi
chmod 600 "$DUAL_CDN_STATE_FILE"

nginx -t
service_restart nginx

# ==================================================
# 追加客户端节点
# ==================================================

NODE_NAME="上行 xhttp+TLS+CDN-A | 下行 xhttp+TLS+CDN-B"
NODE_TAG="%E4%B8%8A%E8%A1%8C%20xhttp%2BTLS%2BCDN-A%20%7C%20%E4%B8%8B%E8%A1%8C%20xhttp%2BTLS%2BCDN-B"

if [[ -n "$BASE_EXTRA_ENC" ]]; then
  BASE_EXTRA_JSON=$(urldecode "$BASE_EXTRA_ENC")
fi

DOWNLOAD_SETTINGS_JSON="\"downloadSettings\":{\"address\":\"$(json_escape "$CDN_B")\",\"port\":443,\"network\":\"xhttp\",\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"$(json_escape "$CDN_B")\",\"allowInsecure\":false,\"alpn\":[\"h2\"],\"fingerprint\":\"chrome\"${ECH_PARAM:+,\"echConfigList\":\"$(json_escape "$(urldecode "$ECH_PARAM")")\"}},\"xhttpSettings\":{\"host\":\"$(json_escape "$CDN_B")\",\"path\":\"$(json_escape "$XHTTP_PATH")\",\"mode\":\"auto\"${BASE_EXTRA_JSON:+,\"extra\":${BASE_EXTRA_JSON}}}}"

if [[ -n "$BASE_EXTRA_JSON" ]]; then
  EXTRA_JSON="${BASE_EXTRA_JSON%\}},${DOWNLOAD_SETTINGS_JSON}}"
else
  EXTRA_JSON="{${DOWNLOAD_SETTINGS_JSON}}"
fi

sed -i "/#${NODE_TAG}\$/d" "$V2RAYN_FILE"
printf '%s\n' "vless://${UUID2}@${CDN_A}:443?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${CDN_A}&fp=chrome&alpn=h2&insecure=0&allowInsecure=0${ECH_PARAM:+&ech=${ECH_PARAM}}&type=xhttp&host=${CDN_A}&path=${XHTTP_PATH}&mode=auto&extra=$(rawurlencode "$EXTRA_JSON")#${NODE_TAG}" >> "$V2RAYN_FILE"
chown "$(stat -c '%u:%g' "$USER_HOME")" "$V2RAYN_FILE"

update_mihomo_file() {
  local source_file="$1"
  local node_file tmp_file

  node_file=$(mktemp)
  tmp_file=$(mktemp)
  awk -v node_name="$NODE_NAME" -v cdn_a="$CDN_A" -v ech_param="$ECH_PARAM" '
    /^  - name: xhttp\+TLS\+H2$/ {
      in_node=1
      print "  - name: " node_name
      next
    }
    in_node && (/^  - name: / || /^proxy-groups:/) { exit }
    !in_node { next }
    ech_param == "" && /^    ech-opts:/ { skip_ech=1; next }
    skip_ech && /^      / { next }
    skip_ech { skip_ech=0 }
    /^    server:/     { print "    server: " cdn_a; next }
    /^    servername:/ { print "    servername: " cdn_a; next }
    /^      host:/     { print "      host: " cdn_a; next }
    { print }
  ' "$source_file" > "$node_file"
  [[ -s "$node_file" ]] || error "未找到 Mihomo 的 xhttp+TLS+H2 节点: $source_file"

  {
    cat <<EOF
      download-settings:
        host: ${CDN_B}
        path: ${XHTTP_PATH}
        server: ${CDN_B}
        port: 443
        tls: true
        alpn:
          - h2
        servername: ${CDN_B}
        client-fingerprint: chrome
EOF

    if [[ -n "$ECH_PARAM" ]]; then
      cat <<'EOF'
        ech-opts:
          enable: true
          query-server-name: cloudflare-ech.com
EOF
    fi

    awk '
      /^  - name: xhttp\+TLS\+H2$/ { in_node=1; next }
      in_node && (/^  - name: / || /^proxy-groups:/) { exit }
      in_node && /^      x-padding-/ { sub(/^      /, "        "); print }
    ' "$source_file"

    cat <<EOF
        reality-opts: { public-key: "" }
        reuse-settings:
          max-concurrency: "16-32"
          c-max-reuse-times: "0"
          h-max-reusable-secs: "1800-3000"
EOF

    awk '
      /^  - name: xhttp\+TLS\+H2$/ { in_node=1; next }
      in_node && (/^  - name: / || /^proxy-groups:/) { exit }
      in_node && /h-keep-alive-period:/ {
        print "          h-keep-alive-period: 0"
        exit
      }
    ' "$source_file"
  } >> "$node_file"

  awk -v node_name="$NODE_NAME" -v node_file="$node_file" '
    skip && !(/^  - name: / || /^proxy-groups:/) { next }
    skip { skip=0 }
    $0 == "  - name: " node_name { skip=1; next }

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

CACHE_BYPASS_RULE="(http.host eq \"${DEFAULT_CDN_DOMAIN}\")"
for domain in "$CDN_A" "$CDN_B"; do
  [[ "$CACHE_BYPASS_RULE" == *"\"${domain}\""* ]] ||
    CACHE_BYPASS_RULE+=" or (http.host eq \"${domain}\")"
done
CACHE_BYPASS_RULE+=" or (http.request.uri.path contains \"${XHTTP_PATH}\")"

echo ""
echo -e "${YELLOW}[+] 建议配置缓存绕过规则:${NC}"
echo "  ${CACHE_BYPASS_RULE}"
echo ""
info "客户端更新订阅后即可看到新节点"


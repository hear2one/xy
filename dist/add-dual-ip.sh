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

echo -e "\n${CYAN}[+] 添加扩展模式：上行 xhttp+Reality IPv4 / IPv6 | 下行 xhttp+Reality IPv6 / IPv4${NC}\n"
echo -e "${YELLOW}[+] 前置条件${NC}"
echo "  1. 已经成功运行主脚本"
echo "  2. 这里只同步 xpadding，不需要 ECH"
echo "  3. VPS 的 IPv4 与 IPv6 都可以访问 443"
echo "  4. 两个 Reality 域名 DNS 分别指向 IPv4 / IPv6，且保持仅 DNS（灰色云朵）"
echo ""

find_client_files
info "读取已有客户端配置: $USER_HOME"

BASE_LINE=$(grep -F '#xhttp%2BReality%20%E4%B8%8A%E4%B8%8B%E8%A1%8C%E4%B8%8D%E5%88%86%E7%A6%BB' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
[[ -n "$BASE_LINE" ]] || error "未找到 xhttp+Reality 上下行不分离节点，无法自动读取参数"

UUID2=$(extract_uri_user "$BASE_LINE")
BASE_SERVER=$(strip_ipv6_brackets "$(extract_uri_server "$BASE_LINE")")
XHTTP_PATH=$(get_query_param "$BASE_LINE" "path" || true)
VLESSENC_ENCRYPTION=$(get_query_param "$BASE_LINE" "encryption" || true)
REALITY_DOMAIN=$(get_query_param "$BASE_LINE" "sni" || true)
PUBLIC_KEY=$(get_query_param "$BASE_LINE" "pbk" || true)
SHORT_ID=$(get_query_param "$BASE_LINE" "sid" || true)
BASE_EXTRA_ENC=$(get_query_param "$BASE_LINE" "extra" || true)

CDN_LINE=$(grep -F '#xhttp%2BTLS%2BH2' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
if [[ -n "$CDN_LINE" ]]; then
  DEFAULT_CDN_DOMAIN=$(get_query_param "$CDN_LINE" "host" || true)
  [[ -n "$DEFAULT_CDN_DOMAIN" ]] || DEFAULT_CDN_DOMAIN=$(get_query_param "$CDN_LINE" "sni" || true)
  [[ -n "$DEFAULT_CDN_DOMAIN" ]] || DEFAULT_CDN_DOMAIN=$(extract_uri_server "$CDN_LINE")
fi

[[ -n "$UUID2" ]] || error "读取 UUID2 失败"
[[ -n "$XHTTP_PATH" ]] || error "读取 XHTTP Path 失败"
[[ -n "$VLESSENC_ENCRYPTION" ]] || error "读取 VLESS Encryption 失败"
[[ -n "$REALITY_DOMAIN" ]] || error "读取 Reality 域名失败"
[[ -n "$PUBLIC_KEY" ]] || error "读取 Reality Public Key 失败"
[[ -n "$SHORT_ID" ]] || error "读取 Reality Short ID 失败"

[[ -f /etc/xhttp-cdn/fallback.env ]] || error "未找到主脚本回落配置，请重新运行主脚本"
# shellcheck disable=SC1090
. /etc/xhttp-cdn/fallback.env

[[ "$FALLBACK_MODE" == "proxy" || "$FALLBACK_MODE" == "static" ]] || error "主脚本回落方式无效，请重新运行主脚本"

if command -v curl >/dev/null 2>&1; then
  IPV4_ADDRESS=$(curl -4 -s --max-time 5 ip.sb || true)
  IPV6_ADDRESS=$(curl -6 -s --max-time 5 ip.sb || true)
fi

if [[ "$BASE_SERVER" == *:* ]]; then
  IPV6_ADDRESS=${IPV6_ADDRESS:-$BASE_SERVER}
else
  IPV4_ADDRESS=${IPV4_ADDRESS:-$BASE_SERVER}
fi

IPV6_ADDRESS=$(strip_ipv6_brackets "$IPV6_ADDRESS")

[[ -n "$IPV4_ADDRESS" ]] || error "IPv4 地址不能为空"
[[ "$IPV4_ADDRESS" != *:* ]] || error "IPv4 地址格式错误"
[[ -n "$IPV6_ADDRESS" ]] || error "IPv6 地址不能为空"
[[ "$IPV6_ADDRESS" == *:* ]] || error "IPv6 地址格式错误"

read -rp "请输入 IPv4 Reality 域名: " REALITY_DOMAIN_V4
[[ -n "$REALITY_DOMAIN_V4" ]] || error "IPv4 Reality 域名不能为空"
[[ "$REALITY_DOMAIN_V4" =~ ^[A-Za-z0-9.-]+$ && "$REALITY_DOMAIN_V4" != "." && "$REALITY_DOMAIN_V4" != ".." ]] || error "IPv4 Reality 域名格式无效"
[[ "$REALITY_DOMAIN_V4" != "$DEFAULT_CDN_DOMAIN" ]] || error "IPv4 Reality 域名不能与 CDN 域名相同"

read -rp "请输入 IPv6 Reality 域名: " REALITY_DOMAIN_V6
[[ -n "$REALITY_DOMAIN_V6" ]] || error "IPv6 Reality 域名不能为空"
[[ "$REALITY_DOMAIN_V6" =~ ^[A-Za-z0-9.-]+$ && "$REALITY_DOMAIN_V6" != "." && "$REALITY_DOMAIN_V6" != ".." ]] || error "IPv6 Reality 域名格式无效"
[[ "$REALITY_DOMAIN_V4" != "$REALITY_DOMAIN_V6" ]] || error "IPv4 / IPv6 Reality 域名不能相同"
[[ "$REALITY_DOMAIN_V6" != "$DEFAULT_CDN_DOMAIN" ]] || error "IPv6 Reality 域名不能与 CDN 域名相同"

if [[ "$FALLBACK_MODE" == "proxy" ]]; then
  [[ -n "$REALITY_FALLBACK_ORIGIN" && -n "$REALITY_FALLBACK_HOST" ]] || error "主脚本 Reality 回落网站为空，请重新运行主脚本"

  if [[ "$REALITY_DOMAIN_V4" == "$REALITY_DOMAIN" ]]; then
    FALLBACK_ORIGIN_V4="$REALITY_FALLBACK_ORIGIN"
    FALLBACK_HOST_V4="$REALITY_FALLBACK_HOST"
  else
    read -rp "请输入 ${REALITY_DOMAIN_V4} 的回落网站: " FALLBACK_ORIGIN_V4
    FALLBACK_ORIGIN_V4=$(normalize_proxy_origin "$FALLBACK_ORIGIN_V4") || error "IPv4 Reality 回落网站格式无效"
    FALLBACK_HOST_V4=${FALLBACK_ORIGIN_V4#*://}
    [[ "$FALLBACK_ORIGIN_V4" != "$REALITY_FALLBACK_ORIGIN" && "$FALLBACK_ORIGIN_V4" != "$CDN_FALLBACK_ORIGIN" ]] || error "不同入口域名不能共用回落网站"
  fi

  if [[ "$REALITY_DOMAIN_V6" == "$REALITY_DOMAIN" ]]; then
    FALLBACK_ORIGIN_V6="$REALITY_FALLBACK_ORIGIN"
    FALLBACK_HOST_V6="$REALITY_FALLBACK_HOST"
  else
    read -rp "请输入 ${REALITY_DOMAIN_V6} 的回落网站: " FALLBACK_ORIGIN_V6
    FALLBACK_ORIGIN_V6=$(normalize_proxy_origin "$FALLBACK_ORIGIN_V6") || error "IPv6 Reality 回落网站格式无效"
    FALLBACK_HOST_V6=${FALLBACK_ORIGIN_V6#*://}
    [[ "$FALLBACK_ORIGIN_V6" != "$REALITY_FALLBACK_ORIGIN" && "$FALLBACK_ORIGIN_V6" != "$CDN_FALLBACK_ORIGIN" ]] || error "不同入口域名不能共用回落网站"
  fi
  [[ "$FALLBACK_ORIGIN_V4" != "$FALLBACK_ORIGIN_V6" ]] || error "IPv4 和 IPv6 Reality 域名不能共用回落网站"
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

  prepare_static_site "$REALITY_DOMAIN_V4"
  prepare_static_site "$REALITY_DOMAIN_V6"
  echo "请将 dist 文件夹上传到 /var/www/"
  echo "IPv4 Reality 页面：dist/${REALITY_DOMAIN_V4}/index.html"
  echo "IPv6 Reality 页面：dist/${REALITY_DOMAIN_V6}/index.html"
  read -rp "确认两个域名的页面准备完成后按 Enter 继续: "
  [[ -f "${STATIC_SITE_DIR}/${REALITY_DOMAIN_V4}/index.html" ]] || error "未找到 IPv4 Reality 页面"
  [[ -f "${STATIC_SITE_DIR}/${REALITY_DOMAIN_V6}/index.html" ]] || error "未找到 IPv6 Reality 页面"
fi

info "IPv4 地址:    $IPV4_ADDRESS"
info "IPv6 地址:    $IPV6_ADDRESS"
info "IPv4 Reality: $REALITY_DOMAIN_V4"
info "IPv6 Reality: $REALITY_DOMAIN_V6"
if [[ "$FALLBACK_MODE" == "proxy" ]]; then
  info "IPv4 回落:    $FALLBACK_ORIGIN_V4"
  info "IPv6 回落:    $FALLBACK_ORIGIN_V6"
fi
info "XHTTP Path:   $XHTTP_PATH"
echo ""

# ==================================================
# 证书、Nginx 与 Xray
# ==================================================

command -v acme.sh >/dev/null 2>&1 || error "未找到 acme.sh，请先运行主脚本"
command -v nginx >/dev/null 2>&1 || error "未找到 nginx，请先运行主脚本"
command -v xray >/dev/null 2>&1 || error "未找到 xray，请先运行主脚本"

ACME_CERT_HOME="/root/.acme.sh/${REALITY_DOMAIN}_ecc"
NGINX_CONF="/etc/nginx/nginx.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
[[ -f "$NGINX_CONF" ]] || error "未找到 $NGINX_CONF"
[[ -f "$XRAY_CONF" ]] || error "未找到 $XRAY_CONF"

DUAL_IP_STATE_FILE="/etc/xhttp-cdn/dual-ip-domains"
DUAL_CDN_STATE_FILE="/etc/xhttp-cdn/dual-cdn-domains"
install -d -m 700 /etc/xhttp-cdn

PREV_DUAL_IP_DOMAINS=()
if [[ -f "$DUAL_IP_STATE_FILE" ]]; then
  mapfile -t PREV_DUAL_IP_DOMAINS < "$DUAL_IP_STATE_FILE"
fi

CERT_DOMAINS=()
add_cert_domain() {
  if [[ -n "$1" && " ${CERT_DOMAINS[*]} " != *" $1 "* ]]; then
    CERT_DOMAINS+=("$1")
  fi
}

add_cert_domain "$REALITY_DOMAIN"
add_cert_domain "$DEFAULT_CDN_DOMAIN"
if [[ -f "$DUAL_CDN_STATE_FILE" ]]; then
  while IFS= read -r domain; do
    add_cert_domain "$domain"
  done < "$DUAL_CDN_STATE_FILE"
fi
add_cert_domain "$REALITY_DOMAIN_V4"
add_cert_domain "$REALITY_DOMAIN_V6"

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

ACME_DOMAIN_ARGS=()
for domain in "${CERT_DOMAINS[@]}"; do
  ACME_DOMAIN_ARGS+=(-d "$domain")
done

if cert_has_all_domains; then
  info "检测到证书已包含 IPv4 / IPv6 Reality 域名，跳过重新签发"
else
  info "申请 / 更新包含 IPv4、IPv6 Reality 域名的证书..."
  if ! ISSUE_OUTPUT=$(acme.sh --issue "${ACME_DOMAIN_ARGS[@]}" \
      --standalone --listen-v6 --keylength ec-256 \
      --pre-hook "${NGINX_STOP_CMD} 2>/dev/null || true" \
      --post-hook "${NGINX_START_CMD} 2>/dev/null || true" 2>&1); then
    grep -Eqi 'Domains not changed|Skipping\. Next renewal time' <<< "$ISSUE_OUTPUT" || {
      echo "$ISSUE_OUTPUT"
      error "IPv4 / IPv6 Reality 域名证书申请失败"
    }
  fi
  echo "$ISSUE_OUTPUT"
fi

info "安装证书..."
acme.sh --install-cert -d "$REALITY_DOMAIN" --ecc \
  --key-file /etc/ssl/private/private.key \
  --fullchain-file /etc/ssl/private/fullchain.cer \
  --reloadcmd "${NGINX_RESTART_CMD}"

append_reality_block() {
  local domain="$1"
  local fallback_origin="$2"
  local fallback_host="$3"

  cat <<EOF
    server {
        listen       8003 ssl;
        http2        on;
        server_name  ${domain};

        ssl_certificate /etc/ssl/private/fullchain.cer;
        ssl_certificate_key /etc/ssl/private/private.key;

        location ^~ /sub/ {
            root /usr/local/nginx/html;
            try_files \$uri =404;
            autoindex off;
            types {
                text/plain txt;
                application/yaml yaml yml;
            }
            default_type text/plain;
            add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0" always;
        }

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

for domain in "${PREV_DUAL_IP_DOMAINS[@]}" "$REALITY_DOMAIN_V4" "$REALITY_DOMAIN_V6"; do
  [[ -n "$domain" && "$domain" != "$REALITY_DOMAIN" ]] || continue
  remove_nginx_server_block "$domain" "$tmp_nginx"
done

# 全局去重：8003 上同名 server 块只保留第一个（清理历史重复残留，V4 复用主域名时必用）
dedupe_nginx_server_blocks() {
  local config="$1"
  local output
  output=$(mktemp)
  awk '
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
      name = ""
      block = $0 ORS
      count_braces($0)
      next
    }
    in_server {
      block = block $0 ORS
      if (name == "" && $0 ~ /server_name/) {
        line = $0
        sub(/^[[:space:]]*server_name[[:space:]]+/, "", line)
        split(line, a, /[[:space:];]/)
        name = a[1]
      }
      count_braces($0)
      if (depth == 0) {
        if (name == "" || !(name in seen)) {
          printf "%s", block
          seen[name] = 1
        }
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

sed -i '$d' "$tmp_nginx"
{
  # 与主 REALITY_DOMAIN 相同的域名不重复 append（主模板已有该 server 块），避免 nginx 冲突警告
  if [[ "$REALITY_DOMAIN_V4" != "$REALITY_DOMAIN" ]]; then
    append_reality_block "$REALITY_DOMAIN_V4" "$FALLBACK_ORIGIN_V4" "$FALLBACK_HOST_V4"
  fi
  if [[ "$REALITY_DOMAIN_V6" != "$REALITY_DOMAIN" ]]; then
    append_reality_block "$REALITY_DOMAIN_V6" "$FALLBACK_ORIGIN_V6" "$FALLBACK_HOST_V6"
  fi
  echo "}"
} >> "$tmp_nginx"

dedupe_nginx_server_blocks "$tmp_nginx"

cat "$tmp_nginx" > "$NGINX_CONF"
rm -f "$tmp_nginx"
info "已写入 IPv4 / IPv6 Reality 独立回落站"

printf '%s\n%s\n' "$REALITY_DOMAIN_V4" "$REALITY_DOMAIN_V6" > "$DUAL_IP_STATE_FILE"
chmod 600 "$DUAL_IP_STATE_FILE"

tmp_xray=$(mktemp)
awk -v base="$REALITY_DOMAIN" -v v4="$REALITY_DOMAIN_V4" -v v6="$REALITY_DOMAIN_V6" '
  function add_name(name) {
    if (name == "") return
    for (i = 1; i <= count; i++) if (names[i] == name) return
    names[++count] = name
  }

  !listen_done && /"listen"[[:space:]]*:[[:space:]]*"0\.0\.0\.0"/ {
    sub(/"0\.0\.0\.0"/, "\"::\"")
    listen_done = 1
  }

  /"serverNames"[[:space:]]*:/ {
    print
    count = 0
    add_name(base)
    add_name(v4)
    add_name(v6)
    for (i = 1; i <= count; i++) {
      printf "                        \"%s\"%s\n", names[i], (i < count ? "," : "")
    }
    skip = 1
    next
  }

  skip && /^[[:space:]]*],[[:space:]]*$/ {
    print "                    ],"
    skip = 0
    next
  }

  skip { next }
  { print }
' "$XRAY_CONF" > "$tmp_xray"
cat "$tmp_xray" > "$XRAY_CONF"
rm -f "$tmp_xray"
info "已写入 Xray Reality serverNames"

nginx -t
xray -test -config "$XRAY_CONF"
service_restart nginx
service_restart xray

# ==================================================
# 追加客户端节点
# ==================================================

NODE_V4_UP_NAME="上行 xhttp+Reality IPv4 | 下行 xhttp+Reality IPv6"
NODE_V6_UP_NAME="上行 xhttp+Reality IPv6 | 下行 xhttp+Reality IPv4"
NODE_V4_UP_TAG="%E4%B8%8A%E8%A1%8C%20xhttp%2BReality%20IPv4%20%7C%20%E4%B8%8B%E8%A1%8C%20xhttp%2BReality%20IPv6"
NODE_V6_UP_TAG="%E4%B8%8A%E8%A1%8C%20xhttp%2BReality%20IPv6%20%7C%20%E4%B8%8B%E8%A1%8C%20xhttp%2BReality%20IPv4"

if [[ -n "$BASE_EXTRA_ENC" ]]; then
  BASE_EXTRA_JSON=$(urldecode "$BASE_EXTRA_ENC")
fi

build_reality_download_extra() {
  local download_ip="$1"
  local download_domain="$2"
  local download_json

  download_json="\"downloadSettings\":{\"address\":\"$(json_escape "$download_ip")\",\"port\":443,\"network\":\"xhttp\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"serverName\":\"$(json_escape "$download_domain")\",\"fingerprint\":\"chrome\",\"shortId\":\"$(json_escape "$SHORT_ID")\",\"publicKey\":\"$(json_escape "$PUBLIC_KEY")\"},\"xhttpSettings\":{\"host\":\"\",\"path\":\"$(json_escape "$XHTTP_PATH")\",\"mode\":\"auto\"${BASE_EXTRA_JSON:+,\"extra\":${BASE_EXTRA_JSON}}}}"

  if [[ -n "$BASE_EXTRA_JSON" ]]; then
    rawurlencode "${BASE_EXTRA_JSON%\}},${download_json}}"
  else
    rawurlencode "{${download_json}}"
  fi
}

sed -i "/#${NODE_V4_UP_TAG}\$/d" "$V2RAYN_FILE"
sed -i "/#${NODE_V6_UP_TAG}\$/d" "$V2RAYN_FILE"
printf '%s\n%s\n' \
  "vless://${UUID2}@$(format_uri_host "$IPV4_ADDRESS"):443?encryption=${VLESSENC_ENCRYPTION}&security=reality&sni=${REALITY_DOMAIN_V4}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}&mode=auto&extra=$(build_reality_download_extra "$IPV6_ADDRESS" "$REALITY_DOMAIN_V6")#${NODE_V4_UP_TAG}" \
  "vless://${UUID2}@$(format_uri_host "$IPV6_ADDRESS"):443?encryption=${VLESSENC_ENCRYPTION}&security=reality&sni=${REALITY_DOMAIN_V6}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}&mode=auto&extra=$(build_reality_download_extra "$IPV4_ADDRESS" "$REALITY_DOMAIN_V4")#${NODE_V6_UP_TAG}" >> "$V2RAYN_FILE"
chown "$(stat -c '%u:%g' "$USER_HOME")" "$V2RAYN_FILE"

build_download_settings_block() {
  local download_ip="$1"
  local download_domain="$2"
  local source_file="$3"

  cat <<EOF
      download-settings:
        path: ${XHTTP_PATH}
        server: ${download_ip}
        port: 443
        tls: true
        alpn:
          - h2
        servername: ${download_domain}
        client-fingerprint: chrome
EOF

  awk '
    /^  - name: xhttp\+Reality 上下行不分离/ { in_node=1; next }
    in_node && (/^  - name: / || /^proxy-groups:/) { exit }
    in_node && /^      x-padding-/ { sub(/^      /, "        "); print }
  ' "$source_file"

  cat <<EOF
        reality-opts:
          public-key: ${PUBLIC_KEY}
          short-id: ${SHORT_ID}
        reuse-settings:
          max-concurrency: "16-32"
          c-max-reuse-times: "0"
          h-max-reusable-secs: "1800-3000"
EOF

  awk '
    /^  - name: xhttp\+Reality 上下行不分离/ { in_node=1; next }
    in_node && (/^  - name: / || /^proxy-groups:/) { exit }
    in_node && /h-keep-alive-period:/ {
      print "          h-keep-alive-period: 0"
      exit
    }
  ' "$source_file"
}

build_mihomo_node_block() {
  local node_name="$1"
  local upload_ip="$2"
  local download_ip="$3"
  local upload_domain="$4"
  local download_domain="$5"
  local source_file="$6"

  awk -v node_name="$node_name" -v upload_ip="$upload_ip" -v upload_domain="$upload_domain" '
    /^  - name: xhttp\+Reality 上下行不分离/ {
      in_node=1
      print "  - name: " node_name
      next
    }
    in_node && (/^  - name: / || /^proxy-groups:/) { exit }
    !in_node { next }
    /^    server:/ { print "    server: " upload_ip; next }
    /^    servername:/ { print "    servername: " upload_domain; next }
    { print }
  ' "$source_file"

  build_download_settings_block "$download_ip" "$download_domain" "$source_file"
}

update_mihomo_file() {
  local source_file="$1"
  local node_file tmp_file

  grep -q '^  - name: xhttp+Reality 上下行不分离' "$source_file" ||
    error "未找到 Mihomo 的 xhttp+Reality 上下行不分离节点: $source_file"

  node_file=$(mktemp)
  tmp_file=$(mktemp)
  {
    build_mihomo_node_block "$NODE_V4_UP_NAME" "$IPV4_ADDRESS" "$IPV6_ADDRESS" "$REALITY_DOMAIN_V4" "$REALITY_DOMAIN_V6" "$source_file"
    echo ""
    build_mihomo_node_block "$NODE_V6_UP_NAME" "$IPV6_ADDRESS" "$IPV4_ADDRESS" "$REALITY_DOMAIN_V6" "$REALITY_DOMAIN_V4" "$source_file"
  } > "$node_file"

  awk -v v4_name="$NODE_V4_UP_NAME" -v v6_name="$NODE_V6_UP_NAME" -v node_file="$node_file" '
    skip && !(/^  - name: / || /^proxy-groups:/) { next }
    skip { skip=0 }

    $0 == "  - name: " v4_name || $0 == "  - name: " v6_name {
      skip=1
      next
    }

    /^proxy-groups:/ {
      while ((getline line < node_file) > 0) print line
      print ""
      inserted=1
      print
      next
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

# ==================================================
# 订阅文件与二维码输出
# ==================================================

update_subscriptions() {
  # 等待 xray 443 监听就绪（restart 后立即自检会撞上启动空窗，报 Could not connect）
  wait_xray_443() {
    local i
    for i in $(seq 1 20); do
      if command -v ss >/dev/null 2>&1; then
        ss -tln | grep -qE ':(443|:443 )' && return 0
      else
        (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null && { exec 3>&- 3<&-; return 0; }
      fi
      sleep 0.5
    done
    return 1
  }
  wait_xray_443 || warn "等待 xray 443 超时，订阅自检可能失败"

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


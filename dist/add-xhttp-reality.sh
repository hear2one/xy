#!/bin/bash
set -e
# ==================================================
# 基础输出与环境检测（对齐 extensions/dual-ip/00-env-utils.sh）
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

service_is_active() {
  if [[ "$OS_ID" == "alpine" ]]; then
    rc-service "$1" status >/dev/null 2>&1
  else
    systemctl is-active --quiet "$1"
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

CDN_LINE=$(grep -F '#xhttp%2BTLS%2BH2' "$V2RAYN_FILE" | head -n1 | tr -d '\r' || true)
DEFAULT_CDN_DOMAIN=""
if [[ -n "$CDN_LINE" ]]; then
  DEFAULT_CDN_DOMAIN=$(get_query_param "$CDN_LINE" "host" || true)
  [[ -n "$DEFAULT_CDN_DOMAIN" ]] || DEFAULT_CDN_DOMAIN=$(get_query_param "$CDN_LINE" "sni" || true)
fi

[[ -n "$BASE_SERVER" ]] || error "读取 VPS 地址失败"
[[ -n "$XHTTP_PATH" ]] || error "读取 XHTTP Path 失败"
[[ -n "$REALITY_DOMAIN" ]] || error "读取 Reality 域名失败"

[[ -f "$XRAY_CONF" ]] || error "未找到 $XRAY_CONF，请先运行主脚本"
command -v python3 >/dev/null 2>&1 || error "未找到 python3，请先安装（apt install python3 / apk add python3）"

install -d -m 700 /etc/xhttp-cdn

# 重复运行：读取上次参数直接重建（幂等），不再提问
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  # 旧版本状态文件不含独立 vlessenc 密钥对 → 提示删除重建
  [[ -n "${VLESSENC_ENCRYPTION:-}" && -n "${VLESSENC_DECRYPTION:-}" ]] || error "状态文件缺少独立 VLESS Encryption 密钥对（旧版本生成），删除 $STATE_FILE 后重跑可重新生成"
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

  # 生成独立参数（与主部署的 reality 密钥/UUID/vlessenc 完全隔离）
  UUID3=$(xray uuid)
  KEY_OUTPUT3=$(xray x25519 2>&1)
  PRIVATE_KEY3=$(echo "$KEY_OUTPUT3" | awk 'tolower($0) ~ /private/ { print $NF; exit }')
  PUBLIC_KEY3=$(echo "$KEY_OUTPUT3"  | awk 'tolower($0) ~ /public/  { print $NF; exit }')
  [[ -z "$UUID3" || -z "$PRIVATE_KEY3" || -z "$PUBLIC_KEY3" ]] && error "生成 UUID / x25519 密钥失败"
  SHORT_ID3=$(echo "$UUID3" | tr -d '-' | cut -c1-8)

  # 独立 VLESS Encryption 密钥对（与主部署 8001 隔离：一份客户端配置泄露只影响本节点）
  info "生成独立 VLESS Encryption 密钥对（xray vlessenc，与主部署隔离）..."
  if ! VLESSENC_OUTPUT=$(xray vlessenc 2>&1) || ! grep -qi "encryption" <<< "$VLESSENC_OUTPUT"; then
    error "VLESS Encryption 密钥生成失败，请确保 Xray 版本支持 vlessenc。输出: $VLESSENC_OUTPUT"
  fi
  VLESSENC_ENCRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '/ML-KEM/{found=1} found && /"encryption"/{print $4; exit}')
  VLESSENC_DECRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '/ML-KEM/{found=1} found && /"decryption"/{print $4; exit}')
  [[ -z "$VLESSENC_ENCRYPTION" ]] && error "未能提取 VLESS Encryption Key，xray vlessenc 输出: $VLESSENC_OUTPUT"
  [[ -z "$VLESSENC_DECRYPTION" ]] && error "未能提取 VLESS Decryption Key，xray vlessenc 输出: $VLESSENC_OUTPUT"

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
info "VLESS Enc:   独立生成（与主部署 8001 隔离，同款 xray vlessenc）"
echo ""

# ==================================================
# 写入 Xray 借证书直连入站（python3 JSON 精确操作，幂等）
# ==================================================

[[ -f "$XRAY_CONF" ]] || error "未找到 $XRAY_CONF"

cp "$XRAY_CONF" "${XRAY_CONF}.bak-xhttp-reality"

info "写入借证书直连入站 (端口 ${XRAY_PORT}) ..."
env XRAY_PORT="$XRAY_PORT" TARGET_HOST="$TARGET_HOST" UUID3="$UUID3" \
  PRIVATE_KEY3="$PRIVATE_KEY3" SHORT_ID3="$SHORT_ID3" XHTTP_PATH="$XHTTP_PATH" \
  VLESSENC_DECRYPTION="$VLESSENC_DECRYPTION" \
  python3 - "$XRAY_CONF" <<'PYEOF'
import json, os, sys

conf_path = sys.argv[1]
port = int(os.environ["XRAY_PORT"])
target = os.environ["TARGET_HOST"]

cfg = json.load(open(conf_path))

# 独立 VLESS Encryption：使用本节点单独生成的 decryption（与主部署 8001 隔离）
decryption = os.environ.get("VLESSENC_DECRYPTION", "") or ""
if not decryption or decryption == "none":
    sys.exit("缺少独立 VLESS Encryption decryption（生成步骤失败或状态文件过期），请删除状态文件重跑")

new_inbound = {
    "listen": "0.0.0.0",
    "port": port,
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": os.environ["UUID3"],
                "level": 0
            }
        ],
        "decryption": decryption
    },
    "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
            "show": False,
            "target": target + ":443",
            "xver": 0,
            "serverNames": [target],
            "privateKey": os.environ["PRIVATE_KEY3"],
            "minClientVer": "26.3.27",
            "shortIds": [os.environ["SHORT_ID3"]]
        },
        "xhttpSettings": {
            "host": "",
            "path": os.environ["XHTTP_PATH"],
            "mode": "auto"
        }
    },
    "sniffing": {
        "enabled": True,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": False,
        "routeOnly": True
    }
}

inbounds = cfg.setdefault("inbounds", [])
replaced = False
for i, ib in enumerate(inbounds):
    if ib.get("port") == port:
        inbounds[i] = new_inbound  # 幂等重建（同端口换参数）
        replaced = True
        break
if not replaced:
    inbounds.append(new_inbound)

with open(conf_path, "w") as f:
    json.dump(cfg, f, indent=4, ensure_ascii=False)
    f.write("\n")

print("OK: inbound port=%d target=%s (%s)" % (port, target, "updated" if replaced else "appended"))
PYEOF
chmod 600 "$XRAY_CONF"

info "校验配置 (xray -test) ..."
if ! xray -test -config "$XRAY_CONF"; then
  mv -f "${XRAY_CONF}.bak-xhttp-reality" "$XRAY_CONF"
  error "xray 配置测试未通过，已回滚原配置，请检查上方输出"
fi
rm -f "${XRAY_CONF}.bak-xhttp-reality"

# 状态文件：重复运行直接重建，不改参数（含独立 vlessenc 密钥对，重建时复用保证配对）
{
  printf 'XRAY_PORT=%q\n' "$XRAY_PORT"
  printf 'TARGET_HOST=%q\n' "$TARGET_HOST"
  printf 'UUID3=%q\n' "$UUID3"
  printf 'PRIVATE_KEY3=%q\n' "$PRIVATE_KEY3"
  printf 'PUBLIC_KEY3=%q\n' "$PUBLIC_KEY3"
  printf 'SHORT_ID3=%q\n' "$SHORT_ID3"
  printf 'XHTTP_PATH=%q\n' "$XHTTP_PATH"
  printf 'VLESSENC_ENCRYPTION=%q\n' "$VLESSENC_ENCRYPTION"
  printf 'VLESSENC_DECRYPTION=%q\n' "$VLESSENC_DECRYPTION"
} > "$STATE_FILE"
chmod 600 "$STATE_FILE"

info "重启 xray ..."
service_restart xray
for _ in $(seq 1 10); do
  service_is_active xray && break
  sleep 1
done
if ! service_is_active xray; then
  if [[ "$OS_ID" == "alpine" ]]; then
    tail -n 30 /var/log/xray/error.log 2>/dev/null || true
  else
    journalctl -u xray -n 30 --no-pager 2>/dev/null | tail -n 30 || true
  fi
  error "xray 启动失败，请根据上方日志排查"
fi
info "xray 运行中，新入站已生效 (TCP ${XRAY_PORT})"
echo ""

# ==================================================
# 追加客户端节点（v2rayn + mihomo 两文件，幂等去重）
# ==================================================

NODE_NAME="xhttp+Reality 借证书直连"
NODE_TAG_ENC="xhttp%2BReality%20%E5%80%9F%E8%AF%81%E4%B9%A6%E7%9B%B4%E8%BF%9E"

# VLESS Encryption：本节点独立密钥对的 encryption（服务端 02 已配同源 decryption，与主部署隔离）
NODE_URI="vless://${UUID3}@$(format_uri_host "$BASE_SERVER"):${XRAY_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=reality&sni=${TARGET_HOST}&fp=chrome&pbk=${PUBLIC_KEY3}&sid=${SHORT_ID3}&type=xhttp&path=${XHTTP_PATH}&mode=auto#${NODE_TAG_ENC}"

# ---- v2rayn (client-config.txt)：按 tag 去重后追加 ----
sed -i "/#${NODE_TAG_ENC}\$/d" "$V2RAYN_FILE"
printf '%s\n' "$NODE_URI" >> "$V2RAYN_FILE"
chown "$(stat -c '%u:%g' "$USER_HOME")" "$V2RAYN_FILE"

# ---- mihomo 节点块（独立小文件，供 awk 插入）----
node_block_file=$(mktemp)
cat > "$node_block_file" <<EOF
  - name: ${NODE_NAME}
    type: vless
    server: ${BASE_SERVER}
    port: ${XRAY_PORT}
    uuid: ${UUID3}
    udp: true
    flow: ""
    tls: true
    encryption: ${VLESSENC_ENCRYPTION}
    network: xhttp
    alpn:
      - h2
    servername: ${TARGET_HOST}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY3}
      short-id: ${SHORT_ID3}
    xhttp-opts:
      path: ${XHTTP_PATH}
      mode: auto
EOF

update_mihomo_file() {
  local source_file="$1"
  local tmp_file

  tmp_file=$(mktemp)
  awk -v node_name="$NODE_NAME" -v block_file="$node_block_file" '
    skip && !(/^  - name: / || /^proxy-groups:/) { next }
    skip { skip = 0 }

    $0 == "  - name: " node_name {
      skip = 1
      next
    }

    /^proxy-groups:/ {
      while ((getline line < block_file) > 0) print line
      print ""
      inserted = 1
      print
      next
    }

    { print }

    END {
      if (!inserted) {
        print ""
        while ((getline line < block_file) > 0) print line
      }
    }
  ' "$source_file" > "$tmp_file"
  cat "$tmp_file" > "$source_file"
  rm -f "$tmp_file"
}

for target_file in "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"; do
  update_mihomo_file "$target_file"
done
rm -f "$node_block_file"
chown "$(stat -c '%u:%g' "$USER_HOME")" "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"

info "已追加客户端节点（mihomo 全量配置的策略组为 include-all，自动包含新节点）"
echo ""
echo "新节点分享链接："
echo "$NODE_URI"
echo ""

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
# 订阅文件与二维码输出（对齐 extensions/dual-ip/04-subscription-output.sh）
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

echo -e "${YELLOW}[+] 别忘了放行新端口${NC}"
echo "  请在防火墙/安全组放行 TCP ${XRAY_PORT}（如 VPS_IP:${XRAY_PORT} 无法访问请检查）"
echo "  验证: https://tcp.ping.pe/${BASE_SERVER}:${XRAY_PORT}"
info "客户端更新订阅后即可看到第 6 个节点：${NODE_NAME}"


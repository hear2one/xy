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

# ==================================================
# 功能开关：无域名单节点版（VLESS-XHTTP-REALITY）
# ==================================================

FEATURE_XPADDING=false
FEATURE_CDN_ECH=false
CDN_ECH_ENABLED=false
CDN_ECH_QUERY=""
GEODATA_AUTO_UPDATE=false
# ==================================================
# 包管理与服务管理适配
# ==================================================

case "$OS_ID" in
  debian|ubuntu)
    pkg_update()  { apt update -y; }
    pkg_install() { apt install -y "$@"; }
    install_build_deps() {
      apt-get install -y gcc g++ libpcre3 libpcre3-dev zlib1g zlib1g-dev openssl libssl-dev libcrypt-dev wget make 2>/dev/null || \
        apt-get install -y gcc g++ libpcre2-dev zlib1g-dev libssl-dev libcrypt-dev wget make
    }
    ;;
  centos|rhel|almalinux|rocky|ol|amzn)
    pkg_update()  { yum makecache; }
    pkg_install() { yum install -y "$@"; }
    install_build_deps() {
      yum groupinstall -y "Development Tools"
      yum install -y pcre-devel zlib-devel openssl-devel wget make 2>/dev/null || \
        yum install -y pcre2-devel zlib-devel openssl-devel wget make
    }
    ;;
  fedora)
    pkg_update()  { dnf makecache; }
    pkg_install() { dnf install -y "$@"; }
    install_build_deps() {
      dnf groupinstall -y "Development Tools"
      dnf install -y pcre-devel zlib-devel openssl-devel wget make 2>/dev/null || \
        dnf install -y pcre2-devel zlib-devel openssl-devel wget make
    }
    ;;
  opensuse*|sles)
    pkg_update()  { zypper refresh; }
    pkg_install() { zypper install -y "$@"; }
    install_build_deps() {
      zypper install -y -t pattern devel_basis
      zypper install -y pcre2-devel zlib-devel libopenssl-devel wget make
    }
    ;;
  alpine)
    pkg_update()  { apk update; }
    pkg_install() { apk add --no-cache "$@"; }
    install_build_deps() {
      apk add --no-cache build-base linux-headers pcre2-dev zlib-dev openssl-dev wget make
    }
    ;;
  *)
    error "不支持的发行版: $OS_ID，目前支持 Debian/Ubuntu/CentOS/RHEL/Fedora/openSUSE/SLES/Alpine"
    ;;
esac

if [[ "$OS_ID" == "alpine" ]]; then
  SERVICE_TYPE="openrc"
  NGINX_STOP_CMD="rc-service nginx stop"
  NGINX_START_CMD="rc-service nginx start"
  NGINX_RESTART_CMD="rc-service nginx restart"
else
  SERVICE_TYPE="systemd"
  NGINX_STOP_CMD="systemctl stop nginx"
  NGINX_START_CMD="systemctl start nginx"
  NGINX_RESTART_CMD="systemctl restart nginx"
fi

service_enable() {
  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    rc-update add "$1" default >/dev/null 2>&1 || true
  else
    systemctl enable "$1" >/dev/null 2>&1 || true
  fi
}

service_restart() {
  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    rc-service "$1" restart || rc-service "$1" start
  else
    systemctl reset-failed "$1" >/dev/null 2>&1 || true
    systemctl restart "$1"
  fi
}

service_is_active() {
  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    rc-service "$1" status >/dev/null 2>&1
  else
    systemctl is-active --quiet "$1"
  fi
}
# ==================================================
# Xray 安装与服务配置
# ==================================================

install_xray() {
  info "Installing Xray-core..."

  if [ -f "/usr/local/bin/xray" ]; then
    info "Xray already installed: $(/usr/local/bin/xray version 2>/dev/null | head -1 || echo 'unknown')"
    return
  fi

  if [[ "$OS_ID" != "alpine" ]]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
    return
  fi

  local arch asset tmpdir
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) error "Alpine 暂不支持当前架构: $arch" ;;
  esac

  command -v unzip >/dev/null 2>&1 || pkg_install unzip
  tmpdir=$(mktemp -d)
  curl -fL "https://github.com/XTLS/Xray-core/releases/latest/download/${asset}" -o "${tmpdir}/xray.zip"
  unzip -q "${tmpdir}/xray.zip" -d "$tmpdir"

  mkdir -p /usr/local/bin /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  install -m 755 "${tmpdir}/xray" /usr/local/bin/xray
  install -m 644 "${tmpdir}/geoip.dat" /usr/local/share/xray/geoip.dat
  install -m 644 "${tmpdir}/geosite.dat" /usr/local/share/xray/geosite.dat
  rm -rf "$tmpdir"

  cat > /etc/init.d/xray << 'XRAYSERVICEEOF'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"

export XRAY_LOCATION_ASSET="/usr/local/share/xray"

depend() {
    need net
}

start_pre() {
    checkpath --directory --mode 0755 /run
    checkpath --directory --mode 0755 /var/log/xray
}
XRAYSERVICEEOF
  chmod +x /etc/init.d/xray
  service_enable xray
}

# ==================================================
# 无域名模式：交互参数（VLESS-XHTTP-REALITY 借第三方 TLS）
# 注：此模式不需要自己的域名/证书/Cloudflare，纯直连单节点
# ==================================================

# 安全护栏：绝不在已部署 Yulinanami 全家桶的机器上覆盖配置
if [[ -f /etc/xhttp-cdn/fallback.env ]]; then
  error "检测到 /etc/xhttp-cdn/fallback.env = 本机已部署 Yulinanami 全家桶（双域名/CDN 模式）。本脚本是【全新无域名 VPS 单节点】安装，会整体覆盖 /usr/local/etc/xray/config.json，禁止在此场景使用。若要在全家桶上追加无域名直连节点，请等待配套扩展脚本。"
fi

# 护栏：已有 xray 配置时需显式确认覆盖（重装场景）
if [[ -s /usr/local/etc/xray/config.json ]]; then
  echo -e "${YELLOW}[WARN]${NC} 检测到已有 /usr/local/etc/xray/config.json"
  read -rp "继续将覆盖该配置，确认覆盖 [y/N]: "
  [[ "${REPLY,,}" == "y" ]] || error "已取消"
fi

echo -e "\n${CYAN}[+] VLESS-XHTTP-REALITY 直连部署（无域名 · 借用第三方网站 TLS）${NC}\n"
echo -e "${YELLOW}[+] 原理说明${NC}"
echo "  - REALITY 协议：服务器实时向目标网站发起真实 TLS 握手并镜像其证书外观，"
echo "    外部看来你的 443 端口就是一个普通大站，全程不需要自己的域名和证书（偷 TLS）"
echo "  - 主动探测 / 未授权连接会被原样转发给目标网站（标准 REALITY 行为，无本地回落页）"
echo -e "  - 客户端内核要求：Xray-core ≥ v25 / V2rayN 最新 / Mihomo ≥ 1.19.23\n"

echo -e "${YELLOW}[+] 借用站点选择建议${NC}"
echo "  - 优先选与 VPS 同国家/同 ASN 的海外大站，且支持 TLS 1.3"
echo "  - 避开套 Cloudflare/Cloudfront 的站点（探测流量会被转发成 CDN 端口转发，易被滥用）"
echo "  - 避开烂大街默认站（apple/microsoft/google 等，易被特征库识别）"
echo "  - 实测候选示例：www.archlinux.org（完美）、www.debian.org；可用本地 SNIProbe 自选"
echo ""

read -rp "监听端口 [默认 443]: " XRAY_PORT
XRAY_PORT=${XRAY_PORT:-443}
[[ "$XRAY_PORT" =~ ^[0-9]{1,5}$ && "$XRAY_PORT" -ge 1 && "$XRAY_PORT" -le 65535 ]] || error "端口格式无效: $XRAY_PORT"
if (ss -Hltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE "[:.]${XRAY_PORT}[[:space:]]"; then
  error "端口 ${XRAY_PORT} 已被占用（本机已有服务监听），请换一个端口重跑"
fi

read -rp "客户端 UUID [回车自动生成]: " UUID
if [[ -n "$UUID" ]]; then
  [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || error "UUID 格式无效（应为标准 UUID，如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）"
fi

read -rp "借用 TLS 的网站域名（不带 https://，默认 www.archlinux.org）: " TARGET_HOST
TARGET_HOST=${TARGET_HOST:-www.archlinux.org}
[[ "$TARGET_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*\.)+[A-Za-z]{2,}$ ]] || error "域名格式无效: $TARGET_HOST"
if grep -Eiq '(^|\.)(cloudflare|cloudfront|fastly|akamai|incapsula|apple|microsoft|google|twitter|facebook)\.(com|net|org|io)$' <<< "$TARGET_HOST"; then
  echo -e "${YELLOW}[WARN]${NC} 该域名疑似知名 CDN / 烂大街默认站（可能被 GFW 特征识别，或探测流量被转发成 CDN 端口转发）"
  read -rp "仍要使用 $TARGET_HOST 吗？[y/N]: "
  [[ "${REPLY,,}" == "y" ]] || error "已取消，请换一个站点重跑"
fi

read -rp "XHTTP path（默认 /+8位随机，直接回车）: " XHTTP_PATH
if [[ -n "$XHTTP_PATH" ]]; then
  [[ "$XHTTP_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || error "path 格式无效（需以 / 开头，仅字母数字 . _ -）"
fi

echo ""
info "端口:       $XRAY_PORT"
info "借用站点:   $TARGET_HOST"
echo ""
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
# ==================================================
# 无域名模式：写入 Xray 配置并测试
# ==================================================

info "写入 /usr/local/etc/xray/config.json ..."
cat > /usr/local/etc/xray/config.json <<XRAYEOF
{
    "log": {
        "loglevel": "info"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "protocol": [
                    "bittorrent"
                ],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:category-ads-all"
                ],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:cn"
                ],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "ip": [
                    "geoip:cn",
                    "geoip:private"
                ],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": ${XRAY_PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "level": 0
                    }
                ],
                "decryption": "${VLESSENC_DECRYPTION}"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "target": "${TARGET_HOST}:443",
                    "xver": 0,
                    "serverNames": [
                        "${TARGET_HOST}"
                    ],
                    "privateKey": "${PRIVATE_KEY}",
                    "minClientVer": "1.8.2",
                    "shortIds": [
                        "${SHORT_ID}"
                    ]
                },
                "xhttpSettings": {
                    "host": "",
                    "path": "${XHTTP_PATH}",
                    "mode": "auto"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
XRAYEOF

info "校验配置 (xray -test) ..."
if ! /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json; then
  echo "---- config.json 内容 ----"
  cat /usr/local/etc/xray/config.json
  error "xray 配置测试未通过，请检查上方输出"
fi
echo ""
# ==================================================
# 无域名模式：启动服务并断言
# ==================================================

info "启用并启动 xray 服务..."
service_enable xray
service_restart xray

for _ in $(seq 1 10); do
  service_is_active xray && break
  sleep 1
done

if ! service_is_active xray; then
  echo -e "${YELLOW}[WARN]${NC} xray 未处于 active 状态，最近日志："
  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    tail -n 30 /var/log/xray/error.log 2>/dev/null || true
  else
    journalctl -u xray -n 30 --no-pager 2>/dev/null | tail -n 30 || true
  fi
  error "xray 启动失败，请根据上方日志排查"
fi

info "xray 服务运行中"
echo ""
# ==================================================
# 无域名模式：输出客户端配置与使用说明
# ==================================================

NODE_NAME="VLESS-XHTTP-REALITY 直连"
VLESS_URI="vless://${UUID}@${VPS_IP_URI}:${XRAY_PORT}?encryption=${VLESSENC_ENCRYPTION}&security=reality&sni=${TARGET_HOST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}&mode=auto#VLESS-XHTTP-REALITY-%E7%9B%B4%E8%BF%9E"

info "生成客户端配置 ..."
{
  echo "# VLESS-XHTTP-REALITY 直连（无域名 · 借用 ${TARGET_HOST} 的 TLS）"
  echo "# 服务器: ${VPS_IP}:${XRAY_PORT}   注意: 端口可能被防火墙挡，记得放行"
  echo "${VLESS_URI}"
  echo ""
  echo "# 客户端内核要求: Xray-core >= v25 / V2rayN 最新 / Mihomo >= 1.19.23"
} > /root/client-config.txt

cat > /root/client-config-mihomo.yaml <<MIHOMOEOF
mixed-port: 10809
allow-lan: false
mode: rule
log-level: warning
dns:
  enable: true
  listen: 0.0.0.0:1053
  nameserver:
    - https://223.5.5.5/dns-query
    - https://doh.pub/dns-query
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
  enhanced-mode: fake-ip
proxies:
  - name: ${NODE_NAME}
    type: vless
    server: ${VPS_IP}
    port: ${XRAY_PORT}
    uuid: ${UUID}
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
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    xhttp-opts:
      path: ${XHTTP_PATH}
      mode: auto
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - ${NODE_NAME}
rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
MIHOMOEOF

chmod 644 /root/client-config.txt /root/client-config-mihomo.yaml

info "节点分享链接（vless://，可直接复制到 V2rayN/小火箭）:"
echo ""
echo "${VLESS_URI}"
echo ""

if ! command -v qrencode >/dev/null 2>&1; then
  pkg_install qrencode >/dev/null 2>&1 || true
fi
if command -v qrencode >/dev/null 2>&1; then
  info "二维码（手机扫码导入）:"
  qrencode -t UTF8 "$VLESS_URI" || true
  echo ""
fi

echo "============================================================"
info "部署完成"
echo ""
echo "产物文件:"
echo "  /root/client-config.txt            分享链接(明文)"
echo "  /root/client-config-mihomo.yaml    Mihomo 最小可用配置"
echo ""
echo "验证:"
echo "  1. 端口放行确认: https://tcp.ping.pe/${VPS_IP}:${XRAY_PORT}"
echo "     (显示 open = 公网可达；VPS 自带防火墙/安全组需先放行 TCP ${XRAY_PORT})"
echo "  2. 手机/PC 导入上方链接或 yaml，测 204 (https://www.google.com/generate_204)"
echo ""
echo "行为说明:"
echo "  - 借用 ${TARGET_HOST} 的 TLS：主动探测者看到的是该站的真实证书与握手"
echo "  - 未授权连接会被 REALITY 原样转发给 ${TARGET_HOST}（标准行为，无本地回落页）"
echo "  - 纯直连无 CDN 无域名：速度最好，但 IP 特征直接暴露；被墙只能换 IP/加 CDN 方案"
echo "============================================================"

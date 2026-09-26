#!/bin/bash
set -e
# ==================================================
# 卸载入口：bash install.sh uninstall [-y]
# 放置于模块最前：仅当第一个参数为 uninstall 时执行，
# 否则直接穿透继续正常安装流程。
# ==================================================

U_RED='\033[0;31m'
U_GREEN='\033[0;32m'
U_YELLOW='\033[0;33m'
U_NC='\033[0m'

uninstall_info()  { echo -e "${U_GREEN}[INFO]${U_NC} $*"; }
uninstall_warn()  { echo -e "${U_YELLOW}[WARN]${U_NC} $*"; }
uninstall_error() { echo -e "${U_RED}[ERROR]${U_NC} $*"; exit 1; }

# 是否检测到本脚本安装痕迹
is_installed() {
  [[ -d /etc/xhttp-cdn ]] || \
  [[ -f /usr/local/etc/xray/config.json ]] || \
  [[ -f /etc/nginx/nginx.conf ]]
}

uninstall_clean() {
  # 1. 停止并禁用服务（systemd / openrc 双适配）
  if command -v systemctl >/dev/null 2>&1; then
    for svc in xray nginx hysteria-server; do
      systemctl stop "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true
    done
    systemctl daemon-reload 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    for svc in xray nginx hysteria-server; do
      rc-service "$svc" stop 2>/dev/null || true
      rc-update del "$svc" default 2>/dev/null || true
    done
  fi

  # 2. Xray
  rm -f /usr/local/bin/xray 2>/dev/null || true
  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray 2>/dev/null || true
  rm -f /etc/systemd/system/xray.service /etc/init.d/xray 2>/dev/null || true

  # 3. Nginx（编译安装产物）
  rm -f /usr/sbin/nginx 2>/dev/null || true
  rm -rf /usr/local/nginx /etc/nginx /var/log/nginx 2>/dev/null || true
  rm -f /etc/systemd/system/nginx.service /etc/init.d/nginx 2>/dev/null || true

  # 4. Hysteria2（若通过扩展 add-hysteria2 安装）
  rm -f /usr/local/bin/hysteria 2>/dev/null || true
  rm -rf /etc/hysteria 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria-server.service /etc/init.d/hysteria-server 2>/dev/null || true
  rm -f /var/log/hysteria-server.log 2>/dev/null || true

  # 5. acme.sh 与 SSL 证书
  #    仅在 crontab -l 成功时才重写，避免清空用户其他定时任务
  if cron_before=$(crontab -l 2>/dev/null); then
    cron_after=$(printf '%s\n' "$cron_before" | grep -v "\.acme\.sh" || true)
    printf '%s\n' "$cron_after" | crontab - 2>/dev/null || true
  fi
  rm -f /usr/local/bin/acme.sh 2>/dev/null || true
  rm -rf /root/.acme.sh 2>/dev/null || true
  rm -f /etc/ssl/private/private.key /etc/ssl/private/fullchain.cer 2>/dev/null || true

  # 6. geodata 自动更新（修改版新增）
  rm -f /etc/cron.d/xhttp-cdn-geodata 2>/dev/null || true
  rm -f /usr/local/bin/xhttp-cdn-update-geodata.sh 2>/dev/null || true

  # 7. 配置目录
  rm -rf /etc/xhttp-cdn 2>/dev/null || true

  # 8. 客户端配置 / 订阅文件
  rm -f /root/client-config.txt /home/*/client-config.txt 2>/dev/null || true
  rm -f /root/client-config-mihomo-full.yaml /home/*/client-config-mihomo-full.yaml 2>/dev/null || true
  rm -f /root/client-config-mihomo-nodes.yaml /home/*/client-config-mihomo-nodes.yaml 2>/dev/null || true
  rm -f /root/subscription-links.txt /home/*/subscription-links.txt 2>/dev/null || true
  rm -f /root/subscription-v2rayn.png /home/*/subscription-v2rayn.png 2>/dev/null || true
  rm -f /root/subscription-mihomo-full.png /home/*/subscription-mihomo-full.png 2>/dev/null || true
  rm -f /root/subscription-mihomo-nodes.png /home/*/subscription-mihomo-nodes.png 2>/dev/null || true

  # 9. 还原 gai.conf（IPv4 优选：仅删本脚本写入的那一行）
  if [[ -f /etc/gai.conf ]]; then
    sed -i '/^precedence ::ffff:0:0\/96  100$/d' /etc/gai.conf 2>/dev/null || true
  fi

  # 10. 静态回落目录：可能含用户自定义页面，只提示不删
  if [[ -d /var/www/dist ]]; then
    uninstall_warn "检测到静态回落目录 /var/www/dist（占位页或你的自定义页面），未删除，请确认后手动清理"
  fi

  echo ""
  uninstall_info "卸载完成：Xray / Nginx / Hysteria2 / acme.sh 证书 / geodata 自动更新 / 配置与订阅文件已移除"
}

if [[ "${1:-}" == "uninstall" ]]; then
  [[ $EUID -ne 0 ]] && uninstall_error "请使用 root 用户运行卸载"

  if ! is_installed; then
    uninstall_warn "未检测到本脚本安装痕迹（/etc/xhttp-cdn 等不存在），可能已经卸载过"
  fi

  if [[ "${2:-}" != "-y" && "${2:-}" != "--yes" ]]; then
    echo ""
    echo "将删除以下内容："
    echo "  - Xray 服务与二进制   (/usr/local/bin/xray、/usr/local/etc/xray、/usr/local/share/xray)"
    echo "  - Nginx 服务与二进制  (/usr/sbin/nginx、/usr/local/nginx、/etc/nginx)"
    echo "  - Hysteria2            (若已通过扩展安装)"
    echo "  - acme.sh 与 SSL 证书  (/root/.acme.sh、/etc/ssl/private/private.key、fullchain.cer)"
    echo "  - geodata 自动更新     (/etc/cron.d/xhttp-cdn-geodata、更新脚本)"
    echo "  - 配置目录             (/etc/xhttp-cdn)"
    echo "  - 客户端配置/订阅文件  (/root/client-config*、/home/*/client-config*、subscription-*)"
    echo ""
    read -r -p "确定卸载? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "已取消卸载"; exit 0; }
  fi

  uninstall_clean
  exit 0
fi
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
# 功能开关：xpadding 版
# ==================================================

FEATURE_XPADDING=true
FEATURE_CDN_ECH=true
FEATURE_FINALMASK=true
XRAY_FINALMASK_ENABLED=false
XRAY_FINALMASK_JSON=""
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
# Xray 安装、升级与服务配置
# ==================================================

validate_xray_version_tag() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]
}

normalize_xray_version_tag() {
  local version="$1"
  validate_xray_version_tag "$version" || return 1
  [[ "$version" == v* ]] || version="v${version}"
  printf '%s' "$version"
}

select_xray_version() {
  local installed=false choice default_choice version
  [[ -x /usr/local/bin/xray ]] && installed=true

  XRAY_SELECTED_MODE="${XRAY_VERSION_MODE:-}"
  XRAY_SELECTED_VERSION="${XRAY_VERSION:-}"

  if [[ -z "$XRAY_SELECTED_MODE" ]]; then
    echo ""
    echo -e "${YELLOW}[+] Xray-core 版本选择${NC}"
    if [[ "$installed" == true ]]; then
      echo "当前版本: $(/usr/local/bin/xray version 2>/dev/null | head -1 || echo 'unknown')"
      echo "  1) 保留当前版本（默认）"
      echo "  2) 安装/升级到最新稳定版"
      echo "  3) 安装/升级到最新预发布版"
      echo "  4) 安装/切换到指定版本"
      default_choice=1
    else
      echo "当前未安装 Xray-core"
      echo "  1) 安装最新稳定版（默认）"
      echo "  2) 安装最新预发布版"
      echo "  3) 安装指定版本"
      default_choice=1
    fi
    read -rp "请选择 [${default_choice}]: " choice
    choice=${choice:-$default_choice}

    if [[ "$installed" == true ]]; then
      case "$choice" in
        1) XRAY_SELECTED_MODE=keep ;;
        2) XRAY_SELECTED_MODE=stable ;;
        3) XRAY_SELECTED_MODE=beta ;;
        4) XRAY_SELECTED_MODE=version ;;
        *) error "Xray 版本选项无效: $choice" ;;
      esac
    else
      case "$choice" in
        1) XRAY_SELECTED_MODE=stable ;;
        2) XRAY_SELECTED_MODE=beta ;;
        3) XRAY_SELECTED_MODE=version ;;
        *) error "Xray 版本选项无效: $choice" ;;
      esac
    fi
  fi

  case "$XRAY_SELECTED_MODE" in
    keep)
      [[ "$installed" == true ]] || error "XRAY_VERSION_MODE=keep 仅适用于已安装 Xray 的系统"
      ;;
    stable|beta) ;;
    version)
      if [[ -z "$XRAY_SELECTED_VERSION" ]]; then
        read -rp "请输入 Xray 版本（例如 v26.9.9）: " XRAY_SELECTED_VERSION
      fi
      version=$(normalize_xray_version_tag "$XRAY_SELECTED_VERSION") || \
        error "Xray 版本格式无效，应为 vX.Y.Z 或 X.Y.Z"
      XRAY_SELECTED_VERSION="$version"
      ;;
    *)
      error "XRAY_VERSION_MODE 只能是 keep、stable、beta 或 version"
      ;;
  esac
}

resolve_alpine_xray_url() {
  local asset="$1" tag
  case "$XRAY_SELECTED_MODE" in
    stable)
      printf 'https://github.com/XTLS/Xray-core/releases/latest/download/%s' "$asset"
      ;;
    beta)
      tag=$(curl -fsSL --retry 3 --retry-delay 5 "https://api.github.com/repos/XTLS/Xray-core/releases" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
      [[ -n "$tag" ]] || error "获取 Xray 最新预发布版本号失败"
      printf 'https://github.com/XTLS/Xray-core/releases/download/%s/%s' "$tag" "$asset"
      ;;
    version)
      printf 'https://github.com/XTLS/Xray-core/releases/download/%s/%s' "$XRAY_SELECTED_VERSION" "$asset"
      ;;
  esac
}

install_xray() {
  local installer status arch asset tmpdir download_url
  local -a install_args=(install -u root)

  select_xray_version
  if [[ "$XRAY_SELECTED_MODE" == keep ]]; then
    info "保留当前 Xray: $(/usr/local/bin/xray version 2>/dev/null | head -1 || echo 'unknown')"
    return
  fi

  case "$XRAY_SELECTED_MODE" in
    stable) info "安装/升级 Xray-core 最新稳定版..." ;;
    beta)
      info "安装/升级 Xray-core 最新预发布版..."
      install_args+=(--beta)
      ;;
    version)
      info "安装/切换 Xray-core ${XRAY_SELECTED_VERSION}..."
      install_args+=(--version "$XRAY_SELECTED_VERSION")
      ;;
  esac

  if [[ "$OS_ID" != "alpine" ]]; then
    installer=$(mktemp)
    curl -fsSL --retry 3 --retry-delay 5 \
      "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o "$installer"
    if bash "$installer" "${install_args[@]}"; then
      rm -f "$installer"
    else
      status=$?
      rm -f "$installer"
      return "$status"
    fi
    info "当前 Xray: $(/usr/local/bin/xray version 2>/dev/null | head -1 || echo 'unknown')"
    return
  fi

  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) error "Alpine 暂不支持当前架构: $arch" ;;
  esac

  command -v unzip >/dev/null 2>&1 || pkg_install unzip
  tmpdir=$(mktemp -d)
  download_url=$(resolve_alpine_xray_url "$asset")
  curl -fL --retry 3 --retry-delay 5 "$download_url" -o "${tmpdir}/xray.zip"
  unzip -q "${tmpdir}/xray.zip" -d "$tmpdir"

  rc-service xray stop >/dev/null 2>&1 || true
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
  info "当前 Xray: $(/usr/local/bin/xray version 2>/dev/null | head -1 || echo 'unknown')"
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
# Optional client-side policy; independent of the VPS IP family.
CDN_DOWNLOAD_SOCKOPT_ENC=""
case "${CDN_DOWNLOAD_IPV4:-false}" in
  true)
    CDN_DOWNLOAD_SOCKOPT_ENC='%2C%22sockopt%22%3A%7B%22domainStrategy%22%3A%22ForceIPv4%22%7D'
    ;;
  false) ;;
  *) echo 'CDN_DOWNLOAD_IPV4 must be true or false' >&2; exit 1 ;;
esac
# ==================================================
# 初始化说明与交互参数
# ==================================================

info "检测到系统: $PRETTY_NAME"

if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  USER_HOME=$(getent passwd 1000 2>/dev/null | cut -d: -f6 || true)
fi
[[ -z "$USER_HOME" || ! -d "$USER_HOME" ]] && USER_HOME="/root"

echo -e "\n${CYAN}[+] XHTTP + CDN 一键部署脚本${NC}\n"
echo -e "${GREEN}[+] 推荐系统: Ubuntu 24.04 / Debian 12${NC}"
echo -e "${YELLOW}[+] 前置条件 (请确认已在 Cloudflare 完成):${NC}"
echo "  1. Reality 域名 DNS → 仅 DNS (灰色云朵)"
echo "  2. CDN 域名 DNS    → 代理开启 (橙色云朵)"
echo "  3. SSL/TLS 加密    → 完全(严格)"
echo "  4. 网络 → gRPC     → 已开启"
echo "  5. 缓存规则         → 部署完成后根据提示配置 (建议)"
if [[ "$FEATURE_CDN_ECH" == true ]]; then
  echo "  6. Edge Certificates → 如需使用 ECH 请先开启"
fi
echo ""

read -rp "请输入 Reality 域名 (如 reality.example.com): " REALITY_DOMAIN
[[ -z "$REALITY_DOMAIN" ]] && error "域名不能为空"
validate_domain "$REALITY_DOMAIN" || error "Reality 域名格式无效"

read -rp "请输入 CDN 域名 (如 cdn.example.com): " CDN_DOMAIN
[[ -z "$CDN_DOMAIN" ]] && error "域名不能为空"
validate_domain "$CDN_DOMAIN" || error "CDN 域名格式无效"
[[ "${REALITY_DOMAIN,,}" != "${CDN_DOMAIN,,}" ]] || error "Reality 域名和 CDN 域名不能相同"

echo ""
echo "  1) IPv4"
echo "  2) IPv6"
read -rp "请选择 IP 类型 [1/2] (默认 1): " IP_CHOICE
IP_CHOICE=${IP_CHOICE:-1}
[[ "$IP_CHOICE" == 1 || "$IP_CHOICE" == 2 ]] || error "IP 类型只能选择 1 或 2"



echo ""
echo -e "${YELLOW}[+] 主动探测回落方式${NC}"
echo "  1) 使用自己的 index.html（默认）"
echo "  2) Nginx 反向代理网站"
read -rp "请选择回落方式 [1/2] (默认 1): " FALLBACK_CHOICE

case "${FALLBACK_CHOICE:-1}" in
  1)
    FALLBACK_MODE="static"
    STATIC_SITE_DIR="/var/www/dist"
    for domain in "$REALITY_DOMAIN" "$CDN_DOMAIN"; do
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
        info "已生成 ${STATIC_SITE_DIR}/${domain}/index.html"
      fi
      chown "$(stat -c '%u:%g' "$USER_HOME")" \
        "${STATIC_SITE_DIR}/${domain}" \
        "${STATIC_SITE_DIR}/${domain}/index.html"
    done
    echo ""
    echo "请将 dist 文件夹上传到 /var/www/"
    echo "Reality 页面：dist/${REALITY_DOMAIN}/index.html"
    echo "CDN 页面：    dist/${CDN_DOMAIN}/index.html"
    echo "可用 SingleFile 抓取网页。"
    read -rp "确认两个域名的页面准备完成后按 Enter 继续: "
    [[ -f "${STATIC_SITE_DIR}/${REALITY_DOMAIN}/index.html" ]] || error "未找到 Reality 域名页面"
    [[ -f "${STATIC_SITE_DIR}/${CDN_DOMAIN}/index.html" ]] || error "未找到 CDN 域名页面"
    ;;
  2)
    FALLBACK_MODE="proxy"
    read -rp "请输入 Reality 域名回落网站 [默认 https://www.stanford.edu]: " REALITY_FALLBACK_ORIGIN
    REALITY_FALLBACK_ORIGIN=$(normalize_proxy_origin "${REALITY_FALLBACK_ORIGIN:-https://www.stanford.edu}") ||
      error "Reality 回落网站格式无效"
    read -rp "请输入 CDN 域名回落网站 [默认 https://www.harvard.edu]: " CDN_FALLBACK_ORIGIN
    CDN_FALLBACK_ORIGIN=$(normalize_proxy_origin "${CDN_FALLBACK_ORIGIN:-https://www.harvard.edu}") ||
      error "CDN 回落网站格式无效"
    [[ "$REALITY_FALLBACK_ORIGIN" != "$CDN_FALLBACK_ORIGIN" ]] ||
      error "Reality 域名和 CDN 域名不能共用同一个回落网站"
    REALITY_FALLBACK_HOST=${REALITY_FALLBACK_ORIGIN#*://}
    CDN_FALLBACK_HOST=${CDN_FALLBACK_ORIGIN#*://}
    ;;
  *)
    error "回落方式只能选择 1 或 2"
    ;;
esac

if [[ "$FEATURE_XPADDING" == true ]]; then
  echo ""
  echo -e "${YELLOW}[+] xpadding 自定义填充${NC}"
  read -rp "请输入 xpadding Header 名 [默认 Referer]: " XHTTP_PADDING_HEADER
  XHTTP_PADDING_HEADER=${XHTTP_PADDING_HEADER:-Referer}
[[ "$XHTTP_PADDING_HEADER" =~ ^[A-Za-z0-9_-]+$ ]] || error "xpadding Header 仅支持字母、数字、下划线和连字符"
  read -rp "请输入 xpadding 参数名 [默认 x_padding]: " XHTTP_PADDING_KEY
  XHTTP_PADDING_KEY=${XHTTP_PADDING_KEY:-x_padding}
[[ "$XHTTP_PADDING_KEY" =~ ^[A-Za-z0-9_-]+$ ]] || error "xpadding 参数名仅支持字母、数字、下划线和连字符"
fi

if [[ "$FEATURE_CDN_ECH" == true ]]; then
  echo ""
  echo -e "${YELLOW}[+] CDN ECH（作用于 CDN-TLS）${NC}"
  read -rp "是否启用 CDN ECH [y/N]: "
  if [[ "${REPLY,,}" == "y" ]]; then
    CDN_ECH_ENABLED=true
    CDN_ECH_QUERY="cloudflare-ech.com+https://223.5.5.5/dns-query"
  else
    CDN_ECH_ENABLED=false
    CDN_ECH_QUERY=""
  fi
fi

echo ""
echo -e "${YELLOW}[+] geoip/geosite 数据自动更新${NC}"
read -rp "是否启用 geodata 自动更新（每周一 04:00 检查更新 geoip.dat/geosite.dat 并重启 Xray）[Y/n]: "
if [[ "${REPLY,,}" =~ ^(y|yes)?$ ]]; then
  GEODATA_AUTO_UPDATE=true
else
  GEODATA_AUTO_UPDATE=false
fi

echo ""
info "Reality: $REALITY_DOMAIN"
info "CDN:     $CDN_DOMAIN"
if [[ "$FALLBACK_MODE" == "static" ]]; then
  info "回落方式: 本地静态页面"
else
  info "回落方式: Nginx 反向代理"
  info "Reality 回落网站: $REALITY_FALLBACK_ORIGIN"
  info "CDN 回落网站:     $CDN_FALLBACK_ORIGIN"
fi
if [[ "$FEATURE_XPADDING" == true ]]; then
  info "xpadding Header:   $XHTTP_PADDING_HEADER"
  info "xpadding Key:      $XHTTP_PADDING_KEY"
fi
if [[ "$FEATURE_CDN_ECH" == true ]]; then
  if [[ "$CDN_ECH_ENABLED" == true ]]; then
    info "CDN ECH:          已开启"
  else
    info "CDN ECH:          未开启"
  fi
fi
if [[ "$GEODATA_AUTO_UPDATE" == true ]]; then
  info "Geodata 自动更新: 已开启"
else
  info "Geodata 自动更新: 未开启"
fi
echo ""

if [[ "$FEATURE_FINALMASK" == true ]]; then
  echo "  - FinalMask 高级伪装默认关闭，可按需启用"
fi

if [[ "$FEATURE_FINALMASK" == true ]]; then
  echo ""
  echo -e "${YELLOW}[+] 服务端 FinalMask 高级伪装${NC}"
  echo "默认关闭。启用后只写入服务端 XHTTP 入站的 streamSettings.finalmask，不会修改客户端 extra/fm。"
  read -rp "是否启用服务端 FinalMask [y/N]: "
  if [[ "${REPLY,,}" == "y" ]]; then
    XRAY_FINALMASK_ENABLED=true
  else
    XRAY_FINALMASK_ENABLED=false
  fi
fi

if [[ "$FEATURE_FINALMASK" == true ]]; then
  if [[ "$XRAY_FINALMASK_ENABLED" == true ]]; then
    info "服务端 FinalMask: 已开启"
  else
    info "服务端 FinalMask: 未开启"
  fi
fi
# ==================================================
# 基础环境安装
# ==================================================

info "[1/6] 安装基础环境"

pkg_update

if [[ "$OS_ID" == "alpine" ]]; then
  pkg_install bash ca-certificates
  update-ca-certificates >/dev/null 2>&1 || true
fi

command -v curl    >/dev/null 2>&1 || pkg_install curl
command -v sudo    >/dev/null 2>&1 || pkg_install sudo
command -v socat   >/dev/null 2>&1 || pkg_install socat
command -v wget    >/dev/null 2>&1 || pkg_install wget
command -v tar     >/dev/null 2>&1 || pkg_install tar
command -v openssl >/dev/null 2>&1 || pkg_install openssl
if ! command -v qrencode >/dev/null 2>&1; then
  info "安装二维码工具 qrencode..."
  if [[ "$OS_ID" == "alpine" ]]; then
    pkg_install libqrencode-tools || warn "qrencode 安装失败，将跳过二维码输出"
  else
    pkg_install qrencode || warn "qrencode 安装失败，将跳过二维码输出"
  fi
fi

if ! command -v crontab >/dev/null 2>&1; then
  case "$OS_ID" in
    debian|ubuntu|opensuse*|sles)
      pkg_install cron
      ;;
    centos|rhel|almalinux|rocky|ol|amzn|fedora|alpine)
      pkg_install cronie
      if [[ "$SERVICE_TYPE" == "openrc" ]]; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
      else
        systemctl enable --now crond 2>/dev/null || true
      fi
      ;;
  esac
fi

info "安装 Xray..."
install_xray
export PATH="/usr/local/bin:$PATH"

info "生成参数..."
UUID1=$(xray uuid)
UUID2=$(xray uuid)
KEY_OUTPUT=$(xray x25519 2>&1)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk 'tolower($0) ~ /private/ { print $NF; exit }')
PUBLIC_KEY=$(echo "$KEY_OUTPUT"  | awk 'tolower($0) ~ /public/  { print $NF; exit }')
[[ -z "$PRIVATE_KEY" ]] && error "未能提取 Private Key，xray x25519 输出: $KEY_OUTPUT"
[[ -z "$PUBLIC_KEY" ]] && error "未能提取 Public Key，xray x25519 输出: $KEY_OUTPUT"
SHORT_ID=$(echo "$UUID1" | tr -d '-' | cut -c1-8)
XHTTP_PATH="/$(echo "$UUID2" | tr -d '-' | cut -c1-8)"

XHTTP_PADDING_PLACEMENT="queryInHeader"
XHTTP_PADDING_METHOD="tokenish"

if [[ "$FEATURE_XPADDING" == true ]]; then
  XRAY_XHTTP_PADDING_JSON=$(cat <<EOF
,
                    "xPaddingObfsMode": true,
                    "xPaddingKey": "${XHTTP_PADDING_KEY}",
                    "xPaddingHeader": "${XHTTP_PADDING_HEADER}",
                    "xPaddingPlacement": "${XHTTP_PADDING_PLACEMENT}",
                    "xPaddingMethod": "${XHTTP_PADDING_METHOD}"
EOF
)
fi

if [[ "$XRAY_FINALMASK_ENABLED" == true ]]; then
  XRAY_FINALMASK_JSON=$(cat <<EOF
,
                "finalmask": {
                    "udp": [
                        {
                            "type": "noise",
                            "settings": {
                                "noise": [
                                    {
                                        "rand": "64-128",
                                        "randRange": "0-255",
                                        "delay": "10-20"
                                    }
                                ]
                            }
                        }
                    ]
                }
EOF
)
fi

if [[ "$CDN_ECH_ENABLED" == true ]]; then
  CDN_ECH_QUERY_ENC=$(echo "$CDN_ECH_QUERY" | sed -e 's/%/%25/g' -e 's/+/%2B/g' -e 's/:/%3A/g' -e 's/\//%2F/g')
fi

info "生成 VLESS Encryption 密钥..."
if ! VLESSENC_OUTPUT=$(xray vlessenc 2>&1) || ! grep -qi "encryption" <<< "$VLESSENC_OUTPUT"; then
  error "VLESS Encryption 密钥生成失败，请确保 Xray 版本支持 vlessenc。输出: $VLESSENC_OUTPUT"
fi
VLESSENC_ENCRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '/ML-KEM/{found=1} found && /"encryption"/{print $4; exit}')
VLESSENC_DECRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '/ML-KEM/{found=1} found && /"decryption"/{print $4; exit}')
[[ -z "$VLESSENC_ENCRYPTION" ]] && error "未能提取 ML-KEM-768 Encryption Key，xray vlessenc 输出: $VLESSENC_OUTPUT"
[[ -z "$VLESSENC_DECRYPTION" ]] && error "未能提取 ML-KEM-768 Decryption Key，xray vlessenc 输出: $VLESSENC_OUTPUT"
if [[ "$IP_CHOICE" == "2" ]]; then
  VPS_IP=$(curl -6 -s --max-time 5 ip.sb)
  [[ -z "$VPS_IP" ]] && error "无法获取 IPv6 地址"
  VPS_IP_URI="[${VPS_IP}]"
else
  VPS_IP=$(curl -4 -s --max-time 5 ip.sb)
  [[ -z "$VPS_IP" ]] && error "无法获取 IPv4 地址"
  VPS_IP_URI="${VPS_IP}"
fi

info "UUID1 (Vision): $UUID1"
info "UUID2 (XHTTP):  $UUID2"
info "Private Key:    $PRIVATE_KEY"
info "Public Key:     $PUBLIC_KEY"
info "Short ID:       $SHORT_ID"
info "Path:           $XHTTP_PATH"
info "VPS IP:         $VPS_IP"
info "VLESS Enc:      已启用 (防 CDN 中间人)"
echo ""
# ==================================================
# 证书申请与复用
# ==================================================

info "[2/6] 申请 / 复用 SSL 证书"

curl https://get.acme.sh | sh
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

acme.sh --set-default-ca --server letsencrypt

prefer_ipv4_for_acme() {
  if [[ "$IP_CHOICE" == "1" ]] && ! grep -q '^precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null; then
    echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
  fi
}

ACME_CERT_HOME="/root/.acme.sh/${REALITY_DOMAIN}_ecc"

have_existing_dual_cert() {
  [[ -f "$ACME_CERT_HOME/${REALITY_DOMAIN}.conf" ]] || return 1
  [[ -f "$ACME_CERT_HOME/fullchain.cer" ]] || return 1
  [[ -f "$ACME_CERT_HOME/${REALITY_DOMAIN}.key" ]] || return 1

  local cert_domains
  cert_domains=$(openssl x509 -in "$ACME_CERT_HOME/fullchain.cer" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://' || true)
  grep -Fxq "$REALITY_DOMAIN" <<< "$cert_domains" &&
    grep -Fxq "$CDN_DOMAIN" <<< "$cert_domains"
}

issue_dual_cert() {
  if [[ "$IP_CHOICE" == "2" ]]; then
    acme.sh --issue -d "$REALITY_DOMAIN" -d "$CDN_DOMAIN" --standalone --listen-v6 --keylength ec-256 \
      --pre-hook "${NGINX_STOP_CMD} 2>/dev/null || true" \
      --post-hook "${NGINX_START_CMD} 2>/dev/null || true"
  else
    prefer_ipv4_for_acme
    acme.sh --issue -d "$REALITY_DOMAIN" -d "$CDN_DOMAIN" --standalone --listen-v4 --request-v4 --keylength ec-256 \
      --pre-hook "${NGINX_STOP_CMD} 2>/dev/null || true" \
      --post-hook "${NGINX_START_CMD} 2>/dev/null || true"
  fi
}

if have_existing_dual_cert; then
  info "检测到已存在的双域名证书，跳过重新签发，直接复用"
else
  info "未检测到可复用的双域名证书，开始申请 (需要 80 端口空闲)..."
  if ! ISSUE_OUTPUT=$(issue_dual_cert 2>&1); then
    grep -Eqi 'Domains not changed|Skipping\. Next renewal time' <<< "$ISSUE_OUTPUT" || {
      echo "$ISSUE_OUTPUT"
      error "双域名证书申请失败"
    }
  fi
  echo "$ISSUE_OUTPUT"
fi

echo ""
# ==================================================
# Nginx 编译安装与服务配置
# ==================================================

info "[3/6] 编译安装 Nginx"
NGINX_VER="1.30.5"
NGINX_SHA256="6c20565aa2325cb82216ae804f4a4ff1875179014759a381c42ddc8e11c4906d"

install_nginx() {
  info "安装编译依赖..."
  install_build_deps

  local build_dir
  build_dir=$(mktemp -d) || error "创建 Nginx 临时构建目录失败"
  cd "$build_dir" || error "无法进入 Nginx 临时构建目录: $build_dir"
  wget -q "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz"
  echo "${NGINX_SHA256}  nginx-${NGINX_VER}.tar.gz" | sha256sum -c - || \
    error "Nginx 源码包 SHA-256 校验失败"
  tar -xf "nginx-${NGINX_VER}.tar.gz"
  cd "nginx-${NGINX_VER}"

  info "编译 Nginx ${NGINX_VER} ..."
  ./configure \
    --prefix=/usr/local/nginx \
    --sbin-path=/usr/sbin/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --with-cc-opt="-Wno-error" \
    --with-http_stub_status_module \
    --with-http_ssl_module \
    --with-http_realip_module \
    --with-http_sub_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-http_v2_module \
    --with-http_v3_module

  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  make install

  cd / && rm -rf "$build_dir"
  mkdir -p /var/log/nginx

  info "创建 ${SERVICE_TYPE} 服务..."
  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    cat > /etc/init.d/nginx << 'SERVICEEOF'
#!/sbin/openrc-run

name="nginx"
description="Nginx web server"
command="/usr/sbin/nginx"
command_args="-g 'daemon off; master_process on;'"
command_background="yes"
pidfile="/run/nginx.pid"
required_files="/etc/nginx/nginx.conf"
extra_started_commands="reload"

depend() {
    need net
}

start_pre() {
    checkpath --directory --mode 0755 /run
    /usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
}

reload() {
    start_pre || return 1
    ebegin "Reloading nginx"
    /usr/sbin/nginx -s reload
    eend $?
}
SERVICEEOF
    chmod +x /etc/init.d/nginx
    service_enable nginx
  else
    cat > /etc/systemd/system/nginx.service << 'SERVICEEOF'
[Unit]
Description=A high performance web server and a reverse proxy server
Documentation=man:nginx(8)
After=network.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=-/bin/kill -s QUIT $MAINPID
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    service_enable nginx.service
  fi
  echo ""
}

if command -v nginx >/dev/null 2>&1 &&
   nginx -v 2>&1 | grep -Fq "nginx/${NGINX_VER}" &&
   nginx -V 2>&1 | grep -q -- '--with-http_v3_module'; then
  info "Nginx ${NGINX_VER} 已安装，跳过编译"
else
  install_nginx
fi
# ==================================================
# 服务端配置生成
# ==================================================

info "[4/6] 生成配置文件"

if [[ "$FALLBACK_MODE" == "static" ]]; then
  [[ -f "${STATIC_SITE_DIR}/${REALITY_DOMAIN}/index.html" ]] || error "未找到 Reality 域名页面"
  [[ -f "${STATIC_SITE_DIR}/${CDN_DOMAIN}/index.html" ]] || error "未找到 CDN 域名页面"
fi

nginx_fallback_config() {
  if [[ "$FALLBACK_MODE" == "static" ]]; then
    cat <<EOF
            root ${STATIC_SITE_DIR}/$1;
            index index.html;
            try_files \$uri \$uri/ /index.html;
EOF
  else
    cat <<EOF
            proxy_pass $2;
            proxy_ssl_server_name on;
            proxy_ssl_name $3;
            proxy_redirect http://$3/ https://\$host/;
            proxy_redirect https://$3/ https://\$host/;
            proxy_set_header Host $3;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
EOF
  fi
}

info "写入 /etc/nginx/nginx.conf ..."
cat > /etc/nginx/nginx.conf << NGINXEOF
user nobody $(id -gn nobody);
worker_processes auto;

error_log /usr/local/nginx/logs/error.log notice;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    set_real_ip_from      127.0.0.1;
    map \$http_cf_connecting_ip \$real_client_ip {
        default \$http_cf_connecting_ip;
        ""      \$remote_addr;
    }
    real_ip_header        X-Real-IP;

    sendfile              on;
    server_tokens         off;
    tcp_nodelay           on;
    tcp_nopush            on;
    client_max_body_size  0;
    gzip                  on;

    add_header X-Content-Type-Options nosniff;

    ssl_session_cache          shared:SSL:16m;
    ssl_session_timeout        1h;
    ssl_session_tickets        off;
    ssl_protocols              TLSv1.3 TLSv1.2;
    ssl_ciphers                TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers  on;
    ssl_stapling               on;
    ssl_stapling_verify        on;
    resolver                   1.1.1.1 8.8.8.8 valid=60s;
    resolver_timeout           2s;

    map \$real_client_ip \$proxy_forwarded_elem {
        ~^[0-9.]+\$        "for=\$real_client_ip";
        ~^[0-9A-Fa-f:.]+\$ "for=\"[\$real_client_ip]\"";
        default           "for=unknown";
    }
    map \$http_forwarded \$proxy_add_forwarded {
        default "\$proxy_forwarded_elem";
    }
    server {
        listen       127.0.0.1:8003 ssl;
        http2        on;
        server_name  ${REALITY_DOMAIN};

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
$(nginx_fallback_config "$REALITY_DOMAIN" "$REALITY_FALLBACK_ORIGIN" "$REALITY_FALLBACK_HOST")
        }
    }

    server {
        listen       127.0.0.1:8003 ssl;
        http2        on;
        server_name  ${CDN_DOMAIN};

        ssl_certificate /etc/ssl/private/fullchain.cer;
        ssl_certificate_key /etc/ssl/private/private.key;

        location / {
$(nginx_fallback_config "$CDN_DOMAIN" "$CDN_FALLBACK_ORIGIN" "$CDN_FALLBACK_HOST")
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

    server {
        listen  80 default_server;
        server_name _;
        return 301 https://\$host\$request_uri;
    }
}
NGINXEOF

install -d -m 700 /etc/xhttp-cdn
{
  printf 'FALLBACK_MODE=%q\n' "$FALLBACK_MODE"
  printf 'GEODATA_AUTO_UPDATE=%q\n' "$GEODATA_AUTO_UPDATE"
  if [[ "$FALLBACK_MODE" == "static" ]]; then
    printf 'STATIC_SITE_DIR=%q\n' "$STATIC_SITE_DIR"
  else
    printf 'REALITY_FALLBACK_ORIGIN=%q\n' "$REALITY_FALLBACK_ORIGIN"
    printf 'REALITY_FALLBACK_HOST=%q\n' "$REALITY_FALLBACK_HOST"
    printf 'CDN_FALLBACK_ORIGIN=%q\n' "$CDN_FALLBACK_ORIGIN"
    printf 'CDN_FALLBACK_HOST=%q\n' "$CDN_FALLBACK_HOST"
  fi
} > /etc/xhttp-cdn/fallback.env
chmod 600 /etc/xhttp-cdn/fallback.env

info "写入 /usr/local/etc/xray/config.json ..."
cat > /usr/local/etc/xray/config.json << XRAYEOF
{
    "log": {
        "loglevel": "info"
    },
    "dns": {
        "servers": [
            {
                "address": "fakedns",
                "domains": [
                    "all"
                ]
            }
        ]
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": [
                    "198.18.0.0/15"
                ],
                "outboundTag": "direct"
            },
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
                    "geoip:cn"
                ],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "ip": [
                    "geoip:private"
                ],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID1}",
                        "level": 0,
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none",
                "fallbacks": [
                    {
                        "dest": "8001",
                        "xver": 0
                    }
                ]
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "target": "8003",
                    "xver": 0,
                    "serverNames": [
                        "${REALITY_DOMAIN}"
                    ],
                    "privateKey": "${PRIVATE_KEY}",
                    "minClientVer": "26.3.27",
                    "shortIds": [
                        "${SHORT_ID}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["fakedns", "http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        },
        {
            "listen": "127.0.0.1",
            "port": 8001,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID2}",
                        "level": 0
                    }
                ],
                "decryption": "${VLESSENC_DECRYPTION}"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {
                    "host": "",
                    "path": "${XHTTP_PATH}",
                    "mode": "auto"${XRAY_XHTTP_PADDING_JSON}
                }${XRAY_FINALMASK_JSON}
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["fakedns", "http", "tls", "quic"],
                "metadataOnly": false,
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct",
            "settings": {
                "domainStrategy": "UseIPv4"
            }
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
XRAYEOF
chmod 600 /usr/local/etc/xray/config.json

info "配置 geodata 自动更新..."
cat > /usr/local/bin/xhttp-cdn-update-geodata.sh <<'UPDATEREOF'
#!/bin/bash
# XHTTP-CDN geoip/geosite 自动更新脚本（由 /etc/cron.d/xhttp-cdn-geodata 每周调用）
# 从 Xray-core 最新 release（含 pre-release）拉取 geoip.dat / geosite.dat，校验后替换并重启 Xray
set -e

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 最新 tag（含 pre-release，按发布时间倒序第一个）
TAG=$(curl -fsSL --retry 3 --retry-delay 5 "https://api.github.com/repos/XTLS/Xray-core/releases" \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
[[ -n "$TAG" ]] || { echo "geodata update: 获取最新版本号失败"; exit 1; }

BASE="https://github.com/XTLS/Xray-core/releases/download/${TAG}"
for f in geoip.dat geosite.dat; do
  curl -fsSL --retry 3 --retry-delay 5 "${BASE}/${f}" -o "${TMP_DIR}/${f}"
  # geodata 是 Protobuf，不是 ZIP；由 Xray 验证实际配置引用的数据。
  [[ -s "${TMP_DIR}/${f}" ]] || { echo "geodata update: ${f} 文件为空"; exit 1; }
done

XRAY_LOCATION_ASSET="$TMP_DIR" xray -test -config /usr/local/etc/xray/config.json

# 两份备份都成功后才能替换，避免使用上次遗留的 .old 文件回滚。
cp /usr/local/share/xray/geoip.dat "${TMP_DIR}/geoip.dat.old"
cp /usr/local/share/xray/geosite.dat "${TMP_DIR}/geosite.dat.old"
restart_xray() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart xray
  else
    rc-service xray restart
  fi
}
rollback_geodata() {
  local status=$?
  trap - ERR
  install -m 644 "${TMP_DIR}/geoip.dat.old" /usr/local/share/xray/geoip.dat
  install -m 644 "${TMP_DIR}/geosite.dat.old" /usr/local/share/xray/geosite.dat
  restart_xray || echo "geodata update: 旧数据已恢复，但 Xray 重启失败" >&2
  echo "geodata update: 更新失败，已恢复旧 geodata" >&2
  exit "$status"
}
trap rollback_geodata ERR
install -m 644 "${TMP_DIR}/geoip.dat"  /usr/local/share/xray/geoip.dat
install -m 644 "${TMP_DIR}/geosite.dat" /usr/local/share/xray/geosite.dat

restart_xray || rollback_geodata
trap - ERR

echo "geodata 已更新至 ${TAG} (geoip.dat + geosite.dat)"
UPDATEREOF
chmod 700 /usr/local/bin/xhttp-cdn-update-geodata.sh

if [[ "$GEODATA_AUTO_UPDATE" == true ]]; then
  cat > /etc/cron.d/xhttp-cdn-geodata <<CRONEOF
# XHTTP-CDN geodata 自动更新（每周一 04:00）
0 4 * * 1 root /usr/local/bin/xhttp-cdn-update-geodata.sh >/dev/null 2>&1
CRONEOF
  chmod 644 /etc/cron.d/xhttp-cdn-geodata
  info "已启用 geodata 自动更新（每周一 04:00）"
else
  rm -f /etc/cron.d/xhttp-cdn-geodata
  info "未启用 geodata 自动更新（可手动执行 /usr/local/bin/xhttp-cdn-update-geodata.sh）"
fi

echo ""
# ==================================================
# 启动服务与配置自检
# ==================================================

info "[5/6] 启动服务"

info "配置证书自动续签命令..."
mkdir -p /etc/ssl/private
acme.sh --install-cert -d "$REALITY_DOMAIN" --ecc \
  --key-file /etc/ssl/private/private.key \
  --fullchain-file /etc/ssl/private/fullchain.cer \
  --reloadcmd "${NGINX_RESTART_CMD}"

info "测试 Nginx 配置..."
nginx -t

info "测试 Xray 配置..."
xray -test -config /usr/local/etc/xray/config.json

info "启动服务..."
service_restart xray
service_restart nginx
# Xray may take about 2 seconds to bind :443 after systemd reports active.
# Subscription checks below still retry and verify the actual response.
sleep 3
service_is_active xray || error "Xray 启动失败"
service_is_active nginx || error "Nginx 启动失败"
info "Xray 运行中"
info "Nginx 运行中"

echo ""
# ==================================================
# 客户端配置生成
# ==================================================

info "[6/6] 生成客户端配置"
# Optional client-side policy; independent of the VPS IP family.
CDN_DOWNLOAD_SOCKOPT_ENC=""
case "${CDN_DOWNLOAD_IPV4:-false}" in
  true)
    CDN_DOWNLOAD_SOCKOPT_ENC='%2C%22sockopt%22%3A%7B%22domainStrategy%22%3A%22ForceIPv4%22%7D'
    ;;
  false) ;;
  *) echo 'CDN_DOWNLOAD_IPV4 must be true or false' >&2; exit 1 ;;
esac
XHTTP_PATH_ENC=${XHTTP_PATH//\//%2F}

if [[ "$FEATURE_XPADDING" == true ]]; then
  XPAD_FIELDS_ENC="%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingMethod%22%3A%22${XHTTP_PADDING_METHOD}%22%2C%22xPaddingPlacement%22%3A%22${XHTTP_PADDING_PLACEMENT}%22%2C%22xPaddingHeader%22%3A%22${XHTTP_PADDING_HEADER}%22%2C%22xPaddingKey%22%3A%22${XHTTP_PADDING_KEY}%22"
  XMUX_ENC="%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%2C%22cMaxReuseTimes%22%3A0%2C%22hMaxReusableSecs%22%3A%221800-3000%22%2C%22hKeepAlivePeriod%22%3A0%7D"
  XPAD_EXTRA_ENC="%7B${XPAD_FIELDS_ENC}%2C${XMUX_ENC}%7D"

  MIHOMO_XPADDING_XHTTP_BLOCK=$(cat <<EOF

      x-padding-obfs-mode: true
      x-padding-key: "${XHTTP_PADDING_KEY}"
      x-padding-header: "${XHTTP_PADDING_HEADER}"
      x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
      x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
)
  MIHOMO_XPADDING_DOWNLOAD_BLOCK=$(cat <<EOF

        x-padding-obfs-mode: true
        x-padding-key: "${XHTTP_PADDING_KEY}"
        x-padding-header: "${XHTTP_PADDING_HEADER}"
        x-padding-placement: "${XHTTP_PADDING_PLACEMENT}"
        x-padding-method: "${XHTTP_PADDING_METHOD}"
EOF
)
  MIHOMO_SC_MIN_POSTS_BLOCK=$(cat <<EOF

      sc-min-posts-interval-ms: 30
EOF
)
  MIHOMO_REUSE_KEEPALIVE_XHTTP=$(cat <<EOF

        h-keep-alive-period: 0
EOF
)
  MIHOMO_REUSE_KEEPALIVE_DOWNLOAD=$(cat <<EOF

          h-keep-alive-period: 0
EOF
)
fi

if [[ "$CDN_ECH_ENABLED" == true ]]; then
  MIHOMO_ECH_PROXY_BLOCK=$(cat <<EOF

    ech-opts:
      enable: true
      query-server-name: cloudflare-ech.com
EOF
)
  MIHOMO_ECH_DOWNLOAD_BLOCK=$(cat <<EOF

        ech-opts:
          enable: true
          query-server-name: cloudflare-ech.com
EOF
)
fi

cat > "$USER_HOME/client-config.txt" << CLIENTEOF
vless://${UUID1}@${VPS_IP_URI}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#reality%2Bvision%20%E7%9B%B4%E8%BF%9E
vless://${UUID2}@${VPS_IP_URI}:443?encryption=${VLESSENC_ENCRYPTION}&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}&mode=auto${XPAD_EXTRA_ENC:+&extra=${XPAD_EXTRA_ENC}}#xhttp%2BReality%20%E4%B8%8A%E4%B8%8B%E8%A1%8C%E4%B8%8D%E5%88%86%E7%A6%BB%20%EF%BC%88%E4%B8%8A%E8%A1%8C%E4%B8%BA%20stream-one%20%E6%A8%A1%E5%BC%8F%EF%BC%89
vless://${UUID2}@${CDN_DOMAIN}:443?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h2&insecure=0&allowInsecure=0${CDN_ECH_QUERY_ENC:+&ech=${CDN_ECH_QUERY_ENC}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH}&mode=auto&extra=%7B${XPAD_FIELDS_ENC:+${XPAD_FIELDS_ENC}%2C%22scMinPostsIntervalMs%22%3A30%2C${XMUX_ENC}%2C}%22downloadSettings%22%3A%7B%22address%22%3A%22${VPS_IP//:/%3A}%22%2C%22port%22%3A443%2C%22network%22%3A%22xhttp%22%2C%22security%22%3A%22reality%22%2C%22realitySettings%22%3A%7B%22show%22%3Afalse%2C%22serverName%22%3A%22${REALITY_DOMAIN}%22%2C%22fingerprint%22%3A%22chrome%22%2C%22shortId%22%3A%22${SHORT_ID}%22%2C%22publicKey%22%3A%22${PUBLIC_KEY}%22%7D%2C%22xhttpSettings%22%3A%7B%22host%22%3A%22%22%2C%22path%22%3A%22${XHTTP_PATH_ENC}%22%2C%22mode%22%3A%22auto%22${XPAD_EXTRA_ENC:+%2C%22extra%22%3A${XPAD_EXTRA_ENC}}%7D%7D%7D#%E4%B8%8A%E8%A1%8C%20xhttp%2BTLS%2BCDN%20%7C%20%E4%B8%8B%E8%A1%8C%20xhttp%2BReality
vless://${UUID2}@${CDN_DOMAIN}:443?encryption=${VLESSENC_ENCRYPTION}&security=tls&sni=${CDN_DOMAIN}&fp=chrome&alpn=h2&insecure=0&allowInsecure=0${CDN_ECH_QUERY_ENC:+&ech=${CDN_ECH_QUERY_ENC}}&type=xhttp&host=${CDN_DOMAIN}&path=${XHTTP_PATH}&mode=auto${XPAD_FIELDS_ENC:+&extra=%7B${XPAD_FIELDS_ENC}%2C%22scMinPostsIntervalMs%22%3A30%2C${XMUX_ENC}%7D}#xhttp%2BTLS%2BH2
vless://${UUID2}@${VPS_IP_URI}:443?encryption=${VLESSENC_ENCRYPTION}&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${XHTTP_PATH}&mode=auto&extra=%7B${XPAD_FIELDS_ENC:+${XPAD_FIELDS_ENC}%2C${XMUX_ENC}%2C}%22downloadSettings%22%3A%7B%22address%22%3A%22${CDN_DOMAIN}%22%2C%22port%22%3A443%2C%22network%22%3A%22xhttp%22%2C%22security%22%3A%22tls%22${CDN_DOWNLOAD_SOCKOPT_ENC}%2C%22tlsSettings%22%3A%7B%22serverName%22%3A%22${CDN_DOMAIN}%22%2C%22allowInsecure%22%3Afalse%2C%22alpn%22%3A%5B%22h2%22%5D%2C%22fingerprint%22%3A%22chrome%22${CDN_ECH_QUERY_ENC:+%2C%22echConfigList%22%3A%22${CDN_ECH_QUERY_ENC}%22}%7D%2C%22xhttpSettings%22%3A%7B%22host%22%3A%22${CDN_DOMAIN}%22%2C%22path%22%3A%22${XHTTP_PATH_ENC}%22%2C%22mode%22%3A%22auto%22${XPAD_EXTRA_ENC:+%2C%22extra%22%3A${XPAD_EXTRA_ENC}}%7D%7D%7D#%E4%B8%8A%E8%A1%8C%20xhttp%2BReality%20%7C%20%E4%B8%8B%E8%A1%8C%20xhttp%2BTLS%2BCDN
CLIENTEOF

# 完整分流配置：保留用户选择的 ECH 配置
cat > "$USER_HOME/client-config-mihomo-full.yaml" << MIHOMOEOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
unified-delay: true

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  prefer-h3: false
  respect-rules: true
  use-system-hosts: false
  cache-algorithm: arc
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - +.lan
    - +.local
    - +.msftconnecttest.com
    - +.msftncsi.com
    - localhost.ptlogin2.qq.com
    - localhost.sec.qq.com
    - +.in-addr.arpa
    - +.ip6.arpa
    - time.*.com
    - time.*.gov
    - pool.ntp.org
    - localhost.work.weixin.qq.com
  default-nameserver:
    - 223.5.5.5
    - 1.2.4.8
  nameserver:
    - https://208.67.222.222/dns-query
    - https://77.88.8.8/dns-query
    - https://1.1.1.1/dns-query
    - https://8.8.4.4/dns-query
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
    - https://doh.pub/dns-query
  direct-nameserver:
    - https://223.5.5.5/dns-query
    - https://doh.pub/dns-query
  nameserver-policy:
    "geosite:private,cn":
      - https://223.5.5.5/dns-query
      - https://doh.pub/dns-query

proxies:
  - name: reality+vision 直连
    type: vless
    server: ${VPS_IP}
    port: 443
    uuid: ${UUID1}
    udp: true
    tls: true
    flow: xtls-rprx-vision
    encryption: "none"
    network: tcp
    alpn:
      - h2
    servername: ${REALITY_DOMAIN}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}

  - name: xhttp+Reality 上下行不分离
    type: vless
    server: ${VPS_IP}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    encryption: ${VLESSENC_ENCRYPTION}
    network: xhttp
    alpn:
      - h2
    servername: ${REALITY_DOMAIN}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    xhttp-opts:
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}

  - name: 上行 xhttp+TLS+CDN | 下行 xhttp+Reality
    type: vless
    server: ${CDN_DOMAIN}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    encryption: ${VLESSENC_ENCRYPTION}
    network: xhttp
    alpn:
      - h2
    servername: ${CDN_DOMAIN}
    client-fingerprint: chrome${MIHOMO_ECH_PROXY_BLOCK}
    xhttp-opts:
      host: ${CDN_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}${MIHOMO_SC_MIN_POSTS_BLOCK}
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}
      download-settings:
        path: ${XHTTP_PATH}
        server: ${VPS_IP}
        port: 443
        tls: true
        alpn:
          - h2
        servername: ${REALITY_DOMAIN}
        client-fingerprint: chrome${MIHOMO_XPADDING_DOWNLOAD_BLOCK}
        reality-opts:
          public-key: ${PUBLIC_KEY}
          short-id: ${SHORT_ID}
        reuse-settings:
          max-concurrency: "16-32"
          c-max-reuse-times: "0"
          h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_DOWNLOAD}

  - name: xhttp+TLS+H2
    type: vless
    server: ${CDN_DOMAIN}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    network: xhttp
    alpn:
      - h2
    servername: ${CDN_DOMAIN}
    client-fingerprint: chrome
    encryption: ${VLESSENC_ENCRYPTION}${MIHOMO_ECH_PROXY_BLOCK}
    xhttp-opts:
      host: ${CDN_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}${MIHOMO_SC_MIN_POSTS_BLOCK}
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}

  - name: 上行 xhttp+Reality | 下行 xhttp+TLS+CDN
    type: vless
    server: ${VPS_IP}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    network: xhttp
    alpn:
      - h2
    servername: ${REALITY_DOMAIN}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    encryption: ${VLESSENC_ENCRYPTION}
    xhttp-opts:
      host: ${CDN_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}
      download-settings:
        host: ${CDN_DOMAIN}
        path: ${XHTTP_PATH}
        server: ${CDN_DOMAIN}
        port: 443
        tls: true
        alpn:
          - h2
        servername: ${CDN_DOMAIN}
        client-fingerprint: chrome${MIHOMO_ECH_DOWNLOAD_BLOCK}${MIHOMO_XPADDING_DOWNLOAD_BLOCK}
        reality-opts: { public-key: "" }
        reuse-settings:
          max-concurrency: "16-32"
          c-max-reuse-times: "0"
          h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_DOWNLOAD}

proxy-groups:
  - name: 前置代理
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    include-all: true
    filter: ^(?!.*(官网|套餐|流量|异常|剩余)).*$
    icon: https://fastly.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/1f9ed.svg

  - name: 节点选择
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    include-all: true
    filter: ^(?!.*(官网|套餐|流量|异常|剩余)).*$
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/adjust.svg

  - name: 谷歌服务
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
      - 全局直连
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/google.svg

  - name: YouTube
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
      - 全局直连
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/youtube.svg

  - name: Netflix
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
      - 全局直连
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/icon/netflix.svg

  - name: 电报消息
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
      - 全局直连
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/telegram.svg

  - name: AI
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/chatgpt.svg

  - name: TikTok
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/icon/tiktok.svg

  - name: 微软服务
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 全局直连
      - 节点选择
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/microsoft.svg

  - name: 苹果服务
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
      - 全局直连
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/apple.svg

  - name: 动画疯
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
    include-all: true
    filter: (?i)台|tw|TW
    icon: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/icon/Bahamut.svg

  - name: 哔哩哔哩港澳台
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 全局直连
      - 节点选择
    include-all: true
    filter: ^(?!.*(官网|套餐|流量|异常|剩余)).*$
    icon: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/icon/bilibili.svg

  - name: Spotify
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
      - 全局直连
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/icon/spotify.svg

  - name: 广告过滤
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - REJECT
      - DIRECT
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/bug.svg

  - name: 全局直连
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - DIRECT
      - 节点选择
    include-all: true
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/link.svg

  - name: 全局拦截
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - REJECT
      - DIRECT
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/block.svg

  - name: 漏网之鱼
    type: select
    interval: 300
    timeout: 3000
    url: https://www.google.com/generate_204
    lazy: true
    max-failed-times: 3
    hidden: false
    proxies:
      - 节点选择
      - 全局直连
    include-all: true
    filter: ^(?!.*(官网|套餐|流量|异常|剩余)).*$
    icon: https://fastly.jsdelivr.net/gh/clash-verge-rev/clash-verge-rev.github.io@main/docs/assets/icons/fish.svg

rule-providers:
  reject:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/reject.txt
    path: ./ruleset/loyalsoldier/reject.yaml
  icloud:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/icloud.txt
    path: ./ruleset/loyalsoldier/icloud.yaml
  apple:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/apple.txt
    path: ./ruleset/loyalsoldier/apple.yaml
  google:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/google.txt
    path: ./ruleset/loyalsoldier/google.yaml
  proxy:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/proxy.txt
    path: ./ruleset/loyalsoldier/proxy.yaml
  direct:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/direct.txt
    path: ./ruleset/loyalsoldier/direct.yaml
  private:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/private.txt
    path: ./ruleset/loyalsoldier/private.yaml
  gfw:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/gfw.txt
    path: ./ruleset/loyalsoldier/gfw.yaml
  tld-not-cn:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/tld-not-cn.txt
    path: ./ruleset/loyalsoldier/tld-not-cn.yaml
  telegramcidr:
    type: http
    behavior: ipcidr
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/telegramcidr.txt
    path: ./ruleset/loyalsoldier/telegramcidr.yaml
  cncidr:
    type: http
    behavior: ipcidr
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/cncidr.txt
    path: ./ruleset/loyalsoldier/cncidr.yaml
  lancidr:
    type: http
    behavior: ipcidr
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/lancidr.txt
    path: ./ruleset/loyalsoldier/lancidr.yaml
  applications:
    type: http
    behavior: classical
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/applications.txt
    path: ./ruleset/loyalsoldier/applications.yaml
  bahamut:
    type: http
    behavior: classical
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/rule/Bahamut.txt
    path: ./ruleset/xiaolin-007/bahamut.yaml
  YouTube:
    type: http
    behavior: classical
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/rule/YouTube.txt
    path: ./ruleset/xiaolin-007/YouTube.yaml
  Netflix:
    type: http
    behavior: classical
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/rule/Netflix.txt
    path: ./ruleset/xiaolin-007/Netflix.yaml
  Spotify:
    type: http
    behavior: classical
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/rule/Spotify.txt
    path: ./ruleset/xiaolin-007/Spotify.yaml
  BilibiliHMT:
    type: http
    behavior: classical
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/rule/BilibiliHMT.txt
    path: ./ruleset/xiaolin-007/BilibiliHMT.yaml
  AI:
    type: http
    behavior: classical
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/rule/AI.txt
    path: ./ruleset/xiaolin-007/AI.yaml
  TikTok:
    type: http
    behavior: classical
    format: yaml
    interval: 86400
    url: https://fastly.jsdelivr.net/gh/xiaolin-007/clash@main/rule/TikTok.txt
    path: ./ruleset/xiaolin-007/TikTok.yaml

rules:
  - DOMAIN-SUFFIX,googleapis.cn,节点选择
  - DOMAIN-SUFFIX,gstatic.com,节点选择
  - DOMAIN-SUFFIX,xn--ngstr-lra8j.com,节点选择
  - DOMAIN-SUFFIX,github.io,节点选择
  - DOMAIN,v2rayse.com,节点选择
  - RULE-SET,applications,全局直连
  - RULE-SET,private,全局直连
  - RULE-SET,reject,广告过滤
  - RULE-SET,icloud,微软服务
  - RULE-SET,apple,苹果服务
  - RULE-SET,YouTube,YouTube
  - RULE-SET,Netflix,Netflix
  - RULE-SET,bahamut,动画疯
  - RULE-SET,Spotify,Spotify
  - RULE-SET,BilibiliHMT,哔哩哔哩港澳台
  - RULE-SET,AI,AI
  - RULE-SET,TikTok,TikTok
  - RULE-SET,google,谷歌服务
  - RULE-SET,proxy,节点选择
  - RULE-SET,gfw,节点选择
  - RULE-SET,tld-not-cn,节点选择
  - RULE-SET,direct,全局直连
  - RULE-SET,lancidr,全局直连,no-resolve
  - RULE-SET,cncidr,全局直连,no-resolve
  - RULE-SET,telegramcidr,电报消息,no-resolve
  - GEOSITE,CN,全局直连
  - GEOIP,LAN,全局直连,no-resolve
  - GEOIP,CN,全局直连,no-resolve
  - MATCH,漏网之鱼
MIHOMOEOF

cat > "$USER_HOME/client-config-mihomo-nodes.yaml" << MIHOMOEOF
# Mihomo 纯节点配置
# 只包含 proxies，适合导入到已有 Mihomo 配置，避免覆盖用户自己的 DNS / 规则 / 策略组

proxies:
  - name: reality+vision 直连
    type: vless
    server: ${VPS_IP}
    port: 443
    uuid: ${UUID1}
    udp: true
    tls: true
    flow: xtls-rprx-vision
    encryption: "none"
    network: tcp
    alpn:
      - h2
    servername: ${REALITY_DOMAIN}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}

  - name: xhttp+Reality 上下行不分离
    type: vless
    server: ${VPS_IP}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    encryption: ${VLESSENC_ENCRYPTION}
    network: xhttp
    alpn:
      - h2
    servername: ${REALITY_DOMAIN}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    xhttp-opts:
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}

  - name: 上行 xhttp+TLS+CDN | 下行 xhttp+Reality
    type: vless
    server: ${CDN_DOMAIN}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    encryption: ${VLESSENC_ENCRYPTION}
    network: xhttp
    alpn:
      - h2
    servername: ${CDN_DOMAIN}
    client-fingerprint: chrome${MIHOMO_ECH_PROXY_BLOCK}
    xhttp-opts:
      host: ${CDN_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}${MIHOMO_SC_MIN_POSTS_BLOCK}
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}
      download-settings:
        path: ${XHTTP_PATH}
        server: ${VPS_IP}
        port: 443
        tls: true
        alpn:
          - h2
        servername: ${REALITY_DOMAIN}
        client-fingerprint: chrome${MIHOMO_XPADDING_DOWNLOAD_BLOCK}
        reality-opts:
          public-key: ${PUBLIC_KEY}
          short-id: ${SHORT_ID}
        reuse-settings:
          max-concurrency: "16-32"
          c-max-reuse-times: "0"
          h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_DOWNLOAD}

  - name: xhttp+TLS+H2
    type: vless
    server: ${CDN_DOMAIN}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    network: xhttp
    alpn:
      - h2
    servername: ${CDN_DOMAIN}
    client-fingerprint: chrome
    encryption: ${VLESSENC_ENCRYPTION}${MIHOMO_ECH_PROXY_BLOCK}
    xhttp-opts:
      host: ${CDN_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}${MIHOMO_SC_MIN_POSTS_BLOCK}
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}

  - name: 上行 xhttp+Reality | 下行 xhttp+TLS+CDN
    type: vless
    server: ${VPS_IP}
    port: 443
    uuid: ${UUID2}
    udp: true
    flow: ""
    tls: true
    network: xhttp
    alpn:
      - h2
    servername: ${REALITY_DOMAIN}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    encryption: ${VLESSENC_ENCRYPTION}
    xhttp-opts:
      host: ${CDN_DOMAIN}
      path: ${XHTTP_PATH}
      mode: auto${MIHOMO_XPADDING_XHTTP_BLOCK}
      reuse-settings:
        max-concurrency: "16-32"
        c-max-reuse-times: "0"
        h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_XHTTP}
      download-settings:
        host: ${CDN_DOMAIN}
        path: ${XHTTP_PATH}
        server: ${CDN_DOMAIN}
        port: 443
        tls: true
        alpn:
          - h2
        servername: ${CDN_DOMAIN}
        client-fingerprint: chrome${MIHOMO_ECH_DOWNLOAD_BLOCK}${MIHOMO_XPADDING_DOWNLOAD_BLOCK}
        reality-opts: { public-key: "" }
        reuse-settings:
          max-concurrency: "16-32"
          c-max-reuse-times: "0"
          h-max-reusable-secs: "1800-3000"${MIHOMO_REUSE_KEEPALIVE_DOWNLOAD}
MIHOMOEOF

chown "$(stat -c '%u:%g' "$USER_HOME")" \
  "$USER_HOME/client-config.txt" \
  "$USER_HOME/client-config-mihomo-full.yaml" \
  "$USER_HOME/client-config-mihomo-nodes.yaml"
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

SUB_TOKEN_FILE="/etc/xhttp-cdn/sub_token"
install -d -m 700 /etc/xhttp-cdn
if [[ -f "$SUB_TOKEN_FILE" ]]; then
  SUB_TOKEN=$(tr -d '\r\n' < "$SUB_TOKEN_FILE")
else
  SUB_TOKEN=$(openssl rand -hex 16)
  echo "$SUB_TOKEN" > "$SUB_TOKEN_FILE"
  chmod 600 "$SUB_TOKEN_FILE"
fi

SUB_DIR="/usr/local/nginx/html/sub/${SUB_TOKEN}"
install -d -m 755 "$SUB_DIR"
cp "$USER_HOME/client-config.txt" "$SUB_DIR/v2rayn-raw.txt"
base64 "$USER_HOME/client-config.txt" | tr -d '\n' > "$SUB_DIR/v2rayn.txt"
cp "$USER_HOME/client-config-mihomo-full.yaml" "$SUB_DIR/mihomo-full.yaml"
cp "$USER_HOME/client-config-mihomo-nodes.yaml" "$SUB_DIR/mihomo-nodes.yaml"

V2RAYN_SUB_URL="https://${REALITY_DOMAIN}/sub/${SUB_TOKEN}/v2rayn.txt"
MIHOMO_FULL_SUB_URL="https://${REALITY_DOMAIN}/sub/${SUB_TOKEN}/mihomo-full.yaml"
MIHOMO_NODES_SUB_URL="https://${REALITY_DOMAIN}/sub/${SUB_TOKEN}/mihomo-nodes.yaml"

V2RAYN_QR_FILE="${USER_HOME}/subscription-v2rayn.png"
MIHOMO_FULL_QR_FILE="${USER_HOME}/subscription-mihomo-full.png"
MIHOMO_NODES_QR_FILE="${USER_HOME}/subscription-mihomo-nodes.png"
SUB_LINKS_FILE="${USER_HOME}/subscription-links.txt"

output_subscription_qr() {
  local label="$1" url="$2" file="$3"
  qrencode -o "$file" -s 8 -m 2 "$url"
  chown "$(stat -c '%u:%g' "$USER_HOME")" "$file"
  echo -e "${YELLOW}[+] ${label}${NC}"
  qrencode -t ANSIUTF8 -m 1 "$url"
}


info "验证订阅链接..."
check_subscription "/sub/${SUB_TOKEN}/v2rayn.txt" "$SUB_DIR/v2rayn.txt"
check_subscription "/sub/${SUB_TOKEN}/mihomo-full.yaml" "$SUB_DIR/mihomo-full.yaml"
check_subscription "/sub/${SUB_TOKEN}/mihomo-nodes.yaml" "$SUB_DIR/mihomo-nodes.yaml"
info "订阅链接自检通过"

cat > "$SUB_LINKS_FILE" << SUBLINKEOF
V2RayN / Shadowrocket 订阅:
$V2RAYN_SUB_URL

Mihomo 完整分流订阅:
$MIHOMO_FULL_SUB_URL

Mihomo 纯节点订阅:
$MIHOMO_NODES_SUB_URL

二维码 PNG 文件:
V2RayN / Shadowrocket: $V2RAYN_QR_FILE
Mihomo 完整分流: $MIHOMO_FULL_QR_FILE
Mihomo 纯节点: $MIHOMO_NODES_QR_FILE
SUBLINKEOF
chown "$(stat -c '%u:%g' "$USER_HOME")" "$SUB_LINKS_FILE"
# ==================================================
# 最终结果输出
# ==================================================

echo -e "\n${CYAN}[+] 部署完成${NC}\n"
echo -e "${YELLOW}[+] 服务端参数${NC}"
echo "Reality 域名:   $REALITY_DOMAIN"
echo "CDN 域名:       $CDN_DOMAIN"
if [[ "$FALLBACK_MODE" == "static" ]]; then
  echo "回落方式:       本地静态页面"
  echo "Reality 页面:   ${STATIC_SITE_DIR}/${REALITY_DOMAIN}"
  echo "CDN 页面:       ${STATIC_SITE_DIR}/${CDN_DOMAIN}"
else
  echo "回落方式:       Nginx 反向代理"
  echo "Reality 回落网站: $REALITY_FALLBACK_ORIGIN"
  echo "CDN 回落网站:    $CDN_FALLBACK_ORIGIN"
fi
echo "VPS IP:         $VPS_IP"
echo "UUID1 (Vision): $UUID1"
echo "UUID2 (XHTTP):  $UUID2"
echo "Public Key:     $PUBLIC_KEY"
echo "Private Key:    $PRIVATE_KEY"
echo "Short ID:       $SHORT_ID"
echo "Path:           $XHTTP_PATH"
echo "VLESS Enc(客户端): $VLESSENC_ENCRYPTION"
echo "VLESS Dec(服务端): $VLESSENC_DECRYPTION"
if [[ "$FEATURE_CDN_ECH" == true ]]; then
  if [[ "$CDN_ECH_ENABLED" == true ]]; then
    echo "CDN ECH:        已开启 (${CDN_ECH_QUERY})"
  else
    echo "CDN ECH:        未开启"
  fi
fi
if [[ "$GEODATA_AUTO_UPDATE" == true ]]; then
  echo "Geodata 自动更新: 已开启（每周一 04:00 cron）"
else
  echo "Geodata 自动更新: 未开启"
fi
echo ""
echo -e "\n${YELLOW}[+] 客户端节点，已保存到 $USER_HOME/client-config.txt${NC}"
cat "$USER_HOME/client-config.txt"
echo ""
echo -e "${YELLOW}[+] Mihomo 完整分流配置，已保存到 $USER_HOME/client-config-mihomo-full.yaml${NC}"
echo -e "${YELLOW}[+] Mihomo 纯节点配置，已保存到 $USER_HOME/client-config-mihomo-nodes.yaml${NC}"
echo ""
echo -e "${YELLOW}[+] 订阅链接（Ctrl Shift + C 复制）${NC}"
echo "V2RayN / Shadowrocket 订阅: $V2RAYN_SUB_URL"
echo "Mihomo 完整分流订阅: $MIHOMO_FULL_SUB_URL"
echo "Mihomo 纯节点订阅: $MIHOMO_NODES_SUB_URL"
info "订阅链接已保存到 $SUB_LINKS_FILE"
echo ""

if command -v qrencode >/dev/null 2>&1; then
  output_subscription_qr "V2RayN / Shadowrocket" "$V2RAYN_SUB_URL" "$V2RAYN_QR_FILE"
  output_subscription_qr "Mihomo 完整分流" "$MIHOMO_FULL_SUB_URL" "$MIHOMO_FULL_QR_FILE"
  output_subscription_qr "Mihomo 纯节点" "$MIHOMO_NODES_SUB_URL" "$MIHOMO_NODES_QR_FILE"
else
  warn "未检测到 qrencode，已跳过订阅二维码输出"
fi

echo -e "${YELLOW}[+] Cloudflare 缓存绕过表达式${NC}"
echo "  (http.host eq \"${CDN_DOMAIN}\") or (http.request.uri.path contains \"${XHTTP_PATH}\")"

if [[ "$FEATURE_FINALMASK" == true ]]; then
  if [[ "$XRAY_FINALMASK_ENABLED" == true ]]; then
    echo "服务端 FinalMask: 已开启"
  else
    echo "服务端 FinalMask: 未开启"
  fi
fi

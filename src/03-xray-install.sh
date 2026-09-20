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

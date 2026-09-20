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
@@include templates/nginx.conf.tmpl
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
@@include templates/xray-config.json.tmpl
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

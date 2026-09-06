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

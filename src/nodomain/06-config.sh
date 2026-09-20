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
                    "minClientVer": "26.3.27",
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
chmod 600 /usr/local/etc/xray/config.json

info "校验配置 (xray -test) ..."
if ! /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json; then
  echo "---- config.json 内容 ----"
  cat /usr/local/etc/xray/config.json
  error "xray 配置测试未通过，请检查上方输出"
fi
echo ""

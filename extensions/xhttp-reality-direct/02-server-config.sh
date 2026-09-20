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

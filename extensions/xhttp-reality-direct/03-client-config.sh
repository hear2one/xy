# ==================================================
# 追加客户端节点（v2rayn + mihomo 两文件，幂等去重）
# ==================================================

NODE_NAME="xhttp+Reality 借证书直连"
NODE_TAG_ENC="xhttp%2BReality%20%E5%80%9F%E8%AF%81%E4%B9%A6%E7%9B%B4%E8%BF%9E"

# VLESS Encryption：与主部署同款（encryption 参数从主节点链接解析，服务端已配同源 decryption）
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

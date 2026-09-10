# ==================================================
# 追加客户端节点
# ==================================================

NODE_HY2_NAME="hysteria2 直连"
NODE_HY2_TAG=$(rawurlencode "$NODE_HY2_NAME")

sed -i "/#${NODE_HY2_TAG}\$/d" "$V2RAYN_FILE"
printf '%s\n' "hysteria2://$(rawurlencode "$HY2_PASSWORD")@$(format_uri_host "$BASE_SERVER"):${HY2_PORT_SPEC}/?sni=${REALITY_DOMAIN}&insecure=0#${NODE_HY2_TAG}" >> "$V2RAYN_FILE"
chown "$(stat -c '%u:%g' "$USER_HOME")" "$V2RAYN_FILE"

update_mihomo_file() {
  local source_file="$1"
  local tmp_file

  tmp_file=$(mktemp)
  awk -v node_name="$NODE_HY2_NAME" \
      -v server="$BASE_SERVER" \
      -v port="$HY2_PORT" \
      -v ports="$HY2_PORT_SPEC" \
      -v hop_enabled="$HY2_HOP_ENABLED" \
      -v hop_interval="$HY2_HOP_INTERVAL" \
      -v password="$HY2_PASSWORD" \
      -v sni="$REALITY_DOMAIN" '
    skip && !(/^  - name: / || /^proxy-groups:/) { next }
    skip { skip=0 }
    $0 == "  - name: " node_name { skip=1; next }

    /^proxy-groups:/ {
      print "  - name: " node_name
      print "    type: hysteria2"
      print "    server: \"" server "\""
      print "    port: " port
      if (hop_enabled == "true") {
        print "    ports: \"" ports "\""
        print "    hop-interval: " hop_interval
      }
      print "    password: \"" password "\""
      print "    sni: " sni
      print "    alpn:"
      print "      - h3"
      print ""
      inserted=1
    }

    { print }

    END {
      if (!inserted) {
        print ""
        print "  - name: " node_name
        print "    type: hysteria2"
        print "    server: \"" server "\""
        print "    port: " port
        if (hop_enabled == "true") {
          print "    ports: \"" ports "\""
          print "    hop-interval: " hop_interval
        }
        print "    password: \"" password "\""
        print "    sni: " sni
        print "    alpn:"
        print "      - h3"
      }
    }
  ' "$source_file" > "$tmp_file"

  cat "$tmp_file" > "$source_file"
  rm -f "$tmp_file"
}

for target_file in "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"; do
  update_mihomo_file "$target_file"
done
chown "$(stat -c '%u:%g' "$USER_HOME")" "$MIHOMO_FULL_FILE" "$MIHOMO_NODES_FILE"

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

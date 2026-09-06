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

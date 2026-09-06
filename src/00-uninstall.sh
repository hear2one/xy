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

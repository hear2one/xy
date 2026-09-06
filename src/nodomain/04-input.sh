# ==================================================
# 无域名模式：交互参数（VLESS-XHTTP-REALITY 借第三方 TLS）
# 注：此模式不需要自己的域名/证书/Cloudflare，纯直连单节点
# ==================================================

# 安全护栏：绝不在已部署 Yulinanami 全家桶的机器上覆盖配置
if [[ -f /etc/xhttp-cdn/fallback.env ]]; then
  error "检测到 /etc/xhttp-cdn/fallback.env = 本机已部署 Yulinanami 全家桶（双域名/CDN 模式）。本脚本是【全新无域名 VPS 单节点】安装，会整体覆盖 /usr/local/etc/xray/config.json，禁止在此场景使用。若要在全家桶上追加无域名直连节点，请等待配套扩展脚本。"
fi

# 护栏：已有 xray 配置时需显式确认覆盖（重装场景）
if [[ -s /usr/local/etc/xray/config.json ]]; then
  echo -e "${YELLOW}[WARN]${NC} 检测到已有 /usr/local/etc/xray/config.json"
  read -rp "继续将覆盖该配置，确认覆盖 [y/N]: "
  [[ "${REPLY,,}" == "y" ]] || error "已取消"
fi

echo -e "\n${CYAN}[+] VLESS-XHTTP-REALITY 直连部署（无域名 · 借用第三方网站 TLS）${NC}\n"
echo -e "${YELLOW}[+] 原理说明${NC}"
echo "  - REALITY 协议：服务器实时向目标网站发起真实 TLS 握手并镜像其证书外观，"
echo "    外部看来你的 443 端口就是一个普通大站，全程不需要自己的域名和证书（偷 TLS）"
echo "  - 主动探测 / 未授权连接会被原样转发给目标网站（标准 REALITY 行为，无本地回落页）"
echo -e "  - 客户端内核要求：Xray-core ≥ v25 / V2rayN 最新 / Mihomo ≥ 1.19.23\n"

echo -e "${YELLOW}[+] 借用站点选择建议${NC}"
echo "  - 优先选与 VPS 同国家/同 ASN 的海外大站，且支持 TLS 1.3"
echo "  - 避开套 Cloudflare/Cloudfront 的站点（探测流量会被转发成 CDN 端口转发，易被滥用）"
echo "  - 避开烂大街默认站（apple/microsoft/google 等，易被特征库识别）"
echo "  - 实测候选示例：www.archlinux.org（完美）、www.debian.org；可用本地 SNIProbe 自选"
echo ""

read -rp "监听端口 [默认 443]: " XRAY_PORT
XRAY_PORT=${XRAY_PORT:-443}
[[ "$XRAY_PORT" =~ ^[0-9]{1,5}$ && "$XRAY_PORT" -ge 1 && "$XRAY_PORT" -le 65535 ]] || error "端口格式无效: $XRAY_PORT"
if (ss -Hltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE "[:.]${XRAY_PORT}[[:space:]]"; then
  error "端口 ${XRAY_PORT} 已被占用（本机已有服务监听），请换一个端口重跑"
fi

read -rp "客户端 UUID [回车自动生成]: " UUID
if [[ -n "$UUID" ]]; then
  [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || error "UUID 格式无效（应为标准 UUID，如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）"
fi

read -rp "借用 TLS 的网站域名（不带 https://，默认 www.archlinux.org）: " TARGET_HOST
TARGET_HOST=${TARGET_HOST:-www.archlinux.org}
[[ "$TARGET_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*\.)+[A-Za-z]{2,}$ ]] || error "域名格式无效: $TARGET_HOST"
if grep -Eiq '(^|\.)(cloudflare|cloudfront|fastly|akamai|incapsula|apple|microsoft|google|twitter|facebook)\.(com|net|org|io)$' <<< "$TARGET_HOST"; then
  echo -e "${YELLOW}[WARN]${NC} 该域名疑似知名 CDN / 烂大街默认站（可能被 GFW 特征识别，或探测流量被转发成 CDN 端口转发）"
  read -rp "仍要使用 $TARGET_HOST 吗？[y/N]: "
  [[ "${REPLY,,}" == "y" ]] || error "已取消，请换一个站点重跑"
fi

read -rp "XHTTP path（默认 /+8位随机，直接回车）: " XHTTP_PATH
if [[ -n "$XHTTP_PATH" ]]; then
  [[ "$XHTTP_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || error "path 格式无效（需以 / 开头，仅字母数字 . _ -）"
fi

echo ""
info "端口:       $XRAY_PORT"
info "借用站点:   $TARGET_HOST"
echo ""

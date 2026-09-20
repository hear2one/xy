# XHTTP + CDN / Reality 一键部署

本仓库提供基于 Xray-core 的 VLESS XHTTP 部署脚本，支持 CDN 与 Reality 上下行分离、xpadding、ECH、H2/H3、双 CDN、双栈、Hysteria2，以及无需自有域名的 XHTTP + Reality 直连模式。

客户端输出支持 V2RayN、Shadowrocket 和 Mihomo。主脚本支持 Debian、Ubuntu、CentOS、RHEL、AlmaLinux、Rocky Linux、Oracle Linux、Amazon Linux、Fedora、openSUSE、SLES 与 Alpine Linux；推荐 Ubuntu 24.04、Debian 12 或 Alpine Linux。

> 客户端和服务端 Xray 内核必须支持 VLESS Encryption 与 XHTTP。xpadding 版建议使用 Xray `26.2.6` 或更高版本，Mihomo `1.19.24` 或更高版本。

## 功能概览

主部署一次生成以下 5 类节点：

1. Reality Vision 直连
2. XHTTP + Reality，上下行不分离
3. 上行 XHTTP + TLS + CDN，下行 XHTTP + Reality
4. XHTTP + TLS + H2
5. 上行 XHTTP + Reality，下行 XHTTP + TLS + CDN

此外提供：

- 普通版和 xpadding + 可选 ECH 版主安装程序
- 服务端 FinalMask 可选开关，默认关闭
- 无需自有域名、证书或 CDN 的独立 XHTTP + Reality 安装程序
- 为现有主部署追加独立端口 XHTTP + Reality 节点
- 上下行不同 CDN、上行 IPv4/下行 IPv6、XHTTP H3/H2-H3、Hysteria2 扩展
- V2RayN/Shadowrocket、Mihomo 完整配置与纯节点配置
- HTTPS 订阅地址及订阅二维码
- geoip/geosite 每周自动更新，替换前校验，失败时回滚
- Xray 可选择保留当前版本、最新稳定版、最新预发布版或指定版本
- FakeDNS、广告拦截与严格禁止回国策略
- 安装脚本内置卸载入口

## 安装脚本

仓库 [`dist/`](./dist/) 中持续维护以下 8 个脚本。README 的一键命令直接下载 `main/dist`，因此会随 `main` 更新；GitHub Release 仅是推送 `v*` 标签时生成的版本快照，可能落后于 `main/dist`，不再作为默认安装入口。

| 脚本 | 用途 | 使用前提 |
| --- | --- | --- |
| `install.sh` | 普通 XHTTP + CDN 主部署 | 自有 Reality 域名和 CDN 域名 |
| `install-xpadding.sh` | xpadding 主部署，ECH 可选 | 同上，客户端内核支持 xpadding |
| `install-xhttp-reality.sh` | 无域名单节点 XHTTP + Reality | 无需自有域名、证书或 CDN |
| `add-xhttp-reality.sh` | 给现有主部署追加独立 Reality 节点 | 已运行主脚本，需放行新 TCP 端口 |
| `add-dual-cdn.sh` | 上行 CDN-A、下行 CDN-B | 已运行主脚本 |
| `add-dual-ip.sh` | 上行 IPv4、下行 IPv6 | VPS 同时具有 IPv4 和 IPv6 |
| `add-quic.sh` | XHTTP H3、H2/H3 上下行分离 | 已运行主脚本，需放行 UDP 端口 |
| `add-hysteria2.sh` | 追加 Hysteria2 节点，可选 UDP 端口跳跃 | 已运行主脚本，需放行 UDP 端口或范围 |

## 快速部署

所有脚本均需 root 权限。Debian/Ubuntu 等系统可先执行 `sudo -i`；Alpine 可执行 `doas -s` 并安装：

```sh
apk add --no-cache bash curl
```

### 有域名：普通版

先在 Cloudflare 配置：

1. Reality 域名设为仅 DNS。
2. CDN 域名开启代理。
3. SSL/TLS 模式设为“完全（严格）”。
4. 开启 gRPC。
5. 为 XHTTP 路径创建绕过缓存规则。

```bash
curl -fsSL https://raw.githubusercontent.com/hear2one/xy/main/dist/install.sh -o ~/install.sh
bash ~/install.sh
```

### 有域名：xpadding 版

xpadding 默认启用，安装过程中可选择 ECH；FinalMask 默认关闭。

```bash
curl -fsSL https://raw.githubusercontent.com/hear2one/xy/main/dist/install-xpadding.sh -o ~/install-xpadding.sh
bash ~/install-xpadding.sh
```

### Xray 版本选择

主安装器和无域名安装器都会在安装阶段询问 Xray 版本。新安装默认使用最新稳定版；检测到已有 Xray 时默认保留当前版本，也可以选择升级到最新稳定版、最新预发布版，或输入 `vX.Y.Z` 指定版本。无人值守运行可预设：

```bash
XRAY_VERSION_MODE=stable bash ~/install-xpadding.sh
XRAY_VERSION_MODE=beta bash ~/install-xpadding.sh
XRAY_VERSION_MODE=version XRAY_VERSION=v26.9.9 bash ~/install-xpadding.sh
XRAY_VERSION_MODE=keep bash ~/install-xpadding.sh
```

`keep` 仅适用于已经安装 Xray 的系统。服务端 REALITY 显式设置 `minClientVer: "26.3.27"`，与 Xray-core 自 v26.7.11 起采用的官方安全基线一致。旧版 Xray 或仍上报 `1.8.2` 的旧 Mihomo 内核会被拒绝，请升级客户端；不要为了兼容而随意降低该值。

### 无域名：XHTTP + Reality 单节点

该模式借用支持 TLS 1.3 的第三方站点作为 Reality target，不安装 Nginx、不申请证书，也不使用 Cloudflare。

```bash
curl -fsSL https://raw.githubusercontent.com/hear2one/xy/main/dist/install-xhttp-reality.sh -o ~/install-xhttp-reality.sh
bash ~/install-xhttp-reality.sh
```

请在 VPS 防火墙和云平台安全组放行所选 TCP 端口。

## 扩展现有部署

先成功运行 `install.sh` 或 `install-xpadding.sh`，再按需执行：

```bash
# 追加独立端口 XHTTP + Reality 节点
curl -fsSL https://raw.githubusercontent.com/hear2one/xy/main/dist/add-xhttp-reality.sh -o ~/add-xhttp-reality.sh
bash ~/add-xhttp-reality.sh

# 上行 CDN-A、下行 CDN-B
curl -fsSL https://raw.githubusercontent.com/hear2one/xy/main/dist/add-dual-cdn.sh -o ~/add-dual-cdn.sh
bash ~/add-dual-cdn.sh

# 上行 IPv4、下行 IPv6
curl -fsSL https://raw.githubusercontent.com/hear2one/xy/main/dist/add-dual-ip.sh -o ~/add-dual-ip.sh
bash ~/add-dual-ip.sh

# XHTTP H3 与 H2/H3 上下行分离
curl -fsSL https://raw.githubusercontent.com/hear2one/xy/main/dist/add-quic.sh -o ~/add-quic.sh
bash ~/add-quic.sh

# Hysteria2
curl -fsSL https://raw.githubusercontent.com/hear2one/xy/main/dist/add-hysteria2.sh -o ~/add-hysteria2.sh
bash ~/add-hysteria2.sh
```

扩展脚本会读取现有配置，并更新客户端文件与 HTTPS 订阅。新增端口需要在系统防火墙和云平台安全组中放行；QUIC/Hysteria2 使用 UDP，追加 Reality 节点使用 TCP。

Hysteria2 可选择单个 UDP 端口，或使用例如 `20000-50000` 的端口跳跃范围。固定端口和范围均不得包含 SSH 实际监听端口、`80`、`443`、`8443` 或 XHTTP H3 的 UDP 端口。启用跳跃时，服务端要求 Hysteria2 2.8.0+ 及 nftables/iptables；脚本会检查并按需更新。V2RayN/Shadowrocket 分享链接使用标准多端口 URI，Mihomo 输出 `ports` 与 `hop-interval`。云平台安全组和系统防火墙必须放行整个 UDP 范围。

## CDN 下行优先 IPv4

客户端没有可用 IPv6，而 CDN 域名同时返回 A/AAAA 记录时，“上行 Reality、下行 TLS + CDN”节点可能首次连接缓慢或超时。新部署时可启用：

```bash
CDN_DOWNLOAD_IPV4=true bash ~/install-xpadding.sh
```

普通版 `install.sh` 同样支持。该选项只在 V2RayN/Xray 分享链接的 CDN 下行 `downloadSettings` 中加入 `sockopt.domainStrategy: ForceIPv4`；不会改变服务器出站、Mihomo 配置、域名、SNI、ECH 或认证参数。默认值为 `false`。

已部署节点可直接编辑客户端 Extra，避免重跑脚本后重新生成密钥。实测与修改示例见 [CDN 下行连接排查](./docs/CDN下行连接排查.md)。

## 回落页面与代理回落

主脚本会让你选择：

- 静态页面：每个入口域名使用 `/var/www/dist/<域名>/index.html`。脚本可创建占位页，也可使用已有页面。
- 反向代理：Reality 与 CDN 域名必须配置不同的 HTTPS 回落站点。

服务器目录 `/var/www/dist` 保存伪装网页；仓库 [`dist/`](./dist/) 保存 GitHub Release 安装脚本，两者用途不同。

## 输出文件

主脚本与扩展会生成或更新：

- `~/client-config.txt`：V2RayN / Shadowrocket 分享链接
- `~/client-config-mihomo-full.yaml`：Mihomo 完整分流配置
- `~/client-config-mihomo-nodes.yaml`：Mihomo 纯节点配置
- `~/subscription-links.txt`：三个 HTTPS 订阅地址
- `~/subscription-v2rayn.png`
- `~/subscription-mihomo-full.png`
- `~/subscription-mihomo-nodes.png`

## 卸载

```bash
bash ~/install.sh uninstall
```

无需交互确认：

```bash
bash ~/install.sh uninstall -y
```

卸载会移除本项目安装的 Xray、Nginx、Hysteria2、证书、配置、订阅和 geodata 更新任务；`/var/www/dist` 中的自定义回落页面会保留。详细清单见 [卸载说明](./docs/9.卸载.md)。

## 安全与路由行为

- CDN XHTTP 入站启用 VLESS Encryption，避免 CDN 中间节点读取代理流量内容。
- Nginx 固定使用 1.30.5，下载后校验 SHA-256，并在私有临时目录中编译。
- Xray 配置包含私钥，生成后权限固定为 `600`。
- Nginx 内部 HTTPS 回源端口 `8003` 仅监听 `127.0.0.1`。
- FakeDNS 地址段 `198.18.0.0/15` 的直连规则固定在阻断规则之前。
- 默认阻断 `geosite:category-ads-all`、`geosite:cn`、`geoip:cn`、私网地址与 BitTorrent。这是广告拦截加严格禁止回国策略，并非国内直连分流。
- FinalMask 仅写入服务端 XHTTP 入站的 `streamSettings.finalmask`，默认关闭；客户端无需手工添加 `fm`。
- ECH 只作用于 CDN TLS 链路，默认关闭。

## 文档

- [环境与 Cloudflare 配置](./docs/1.环境配置.md)
- [手动文件配置](./docs/2.文件配置.md)
- [xpadding 配置](./docs/3.xpadding配置.md)
- [ECH 配置](./docs/4.ECH配置.md)
- [链路流程图](./docs/5.流程图.md)
- [双 CDN 扩展](./docs/6.拓展-上下行不同CDN.md)
- [IPv4/IPv6 扩展](./docs/7.拓展-上下行IPv4IPv6.md)
- [XHTTP H3 扩展](./docs/8.拓展-XHTTP-H3.md)
- [Hysteria2 扩展](./docs/9.拓展-Hysteria2.md)
- [代码审查记录](./docs/代码审查记录.md)

## 开发、检查与发布

修改 `src/`、`extensions/` 或 `templates/` 后，在 Bash 环境运行：

```bash
for builder in .github/scripts/build-*.sh; do bash "$builder"; done
bash .github/scripts/check.sh
```

检查会重新构建全部 8 个安装脚本，执行 Bash 语法与模板检查，确认 [`dist/`](./dist/) 与源码生成结果逐字节一致，并运行输入校验和 geodata 更新回归测试。

CI 还会校验生成目录、提交目录和 README 使用同一份 8 文件清单，防止新增功能时漏交 `dist` 或 `main/dist` 下载命令。

提交 `main` 后，README 的默认安装地址会直接取得更新后的 `dist`。推送新的 `v*` 标签后，[Release 工作流](./.github/workflows/release.yml) 才会构建、校验并把 8 个脚本保存为对应版本的 GitHub Release 快照。需要可复现部署时，应使用明确的 Release 标签地址，而不是 `releases/latest`。

## 参考资料

- [Xray XHTTP: Beyond REALITY](https://github.com/XTLS/Xray-core/discussions/4113)
- [XHTTP + CDN 上下行分离](https://github.com/XTLS/Xray-core/discussions/4118)
- [Xray VLESS 分享链接标准](https://github.com/XTLS/Xray-core/discussions/716)
- [Xray transport 配置](https://xtls.github.io/config/transport.html)
- [Mihomo VLESS 文档](https://wiki.metacubex.one/config/proxies/vless/)
- [Mihomo transport 文档](https://wiki.metacubex.one/config/proxies/transport/)
- [Cloudflare ECH 文档](https://developers.cloudflare.com/ssl/edge-certificates/ech/)
- [XHTTP 原理与上下行分离介绍](https://habr.com/en/articles/990208/)

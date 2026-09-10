# CDN 下行连接排查

2026-09-10，在 Windows、v2rayN 7.25.0、Xray 26.9.9 环境中，用独立测试进程复测上下行分离节点。没有重启用户的活动代理，也没有修改活动节点。

## 观察结果

- 原配置此前出现 10 秒超时；放宽测试上限后，首次请求 14.10 秒成功，复用连接后为 0.80、0.48 秒。
- 本次原配置两次冷启动为 9.74、2.13 秒；直接使用 DNS 返回的 IPv4 地址，四次均成功，为 1.02–2.36 秒。
- 两个 IPv6 地址各测试两次，均出现 `connectex: A socket operation was attempted to an unreachable network`。测试代理返回的 HTTP 503 是本地连接失败结果，不是 Cloudflare 返回的服务错误。
- 保留域名和 ECH、仅限制下行 IPv4 后，初测两次为 1.32、2.19 秒；额外五次独立进程冷启动全部返回 HTTP 204，耗时 2.28、2.15、1.50、1.02、1.11 秒。

这些结果支持在该客户端网络下选择 IPv4，不能证明历史全部延迟均由 IPv6 导致，也不保证所有网络都受益。每次重启进程隔离 Xray 连接池，但系统 DNS 缓存可能仍被复用。

## 已有节点修改

在 XHTTP Extra 的 `downloadSettings` 对象内加入以下字段，与 `tlsSettings`、`xhttpSettings` 同级；若已有 `sockopt`，合并字段并保留其他选项：

```json
"sockopt": {
  "domainStrategy": "ForceIPv4"
}
```

保留 `address` 域名、Host、SNI、ECH、UUID、加密参数和路径。不要固定本次测试的 CDN IP。恢复原行为时删除新增字段；仅 IPv6 网络不要启用此选项。

## 新部署与代码范围

主安装器读取可选环境变量 `CDN_DOWNLOAD_IPV4=true`，默认 `false`，非法值会在输入阶段报错。`src/common/cdn-download-options.sh` 生成 URI 编码片段，由客户端链接模板仅插入 TLS+CDN 下行的 `downloadSettings`。默认生成的其他四个节点不变。Mihomo 及扩展脚本未增加该选项，不声称跨客户端等价支持。

这不更改 v2rayN 测试超时。需要减少慢连接误判时，可另将客户端测试上限设为 30 秒，但这不会提高实际链路速度。

依据：[Xray Sockopt 官方说明](https://xtls.github.io/config/transports/sockopt.html)。`ForceIPv4` 使用内置 DNS（未配置则系统 DNS）只解析 IPv4；没有符合要求的地址时失败，不回退到 IPv6。

仓库只保存通用代码及汇总结果，不包含个人节点链接、密钥或原始运行配置。

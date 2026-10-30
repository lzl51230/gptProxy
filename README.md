# ChatGPT Proxy

适用于 macOS 14 及以上版本的启动器，可将 OpenAI 桌面应用的流量转发到用户指定的本地 SOCKS5 代理。默认上游代理端口为 `7890`。

启动器不会修改 macOS 系统代理设置，而是在 `127.0.0.1:17890` 运行本地 TCP 中继。内置的 ProxyBridge 配置会匹配 `com.openai.*`、旧版 `com.openai.chat` 和 `ChatGPT`，并将匹配的流量转发到中继。启动器要求使用支持 Codex 的新版 ChatGPT 桌面客户端；检测到旧版 `com.openai.chat` 客户端时，会提示更新。

“打开 .codex”按钮可打开当前用户的 Codex 配置目录；目录不存在时会自动创建。

## 构建

需要 Xcode 16 或更高版本。

```sh
make verify
```

构建后的应用位于 `build/ChatGPT Proxy.app`，统一安装包位于 `dist/ChatGPT-Proxy-2.2-Universal.pkg`。运行安装包会将 ChatGPT Proxy 和 ProxyBridge 一并安装到 `/Applications`。

本项目未配置 Apple Developer ID Application 或 Installer 证书，因此统一安装包未签名。在其他 Mac 上安装时，可通过 Finder 右键菜单打开，或在“隐私与安全性”设置中允许运行。构建过程会先验证上游 ProxyBridge 安装包，再提取其组件；安装后的 ProxyBridge 应用和系统扩展保留上游代码签名。


后台监控与自动切换：
- 打开应用即监控，关闭窗口后继续驻留菜单栏；菜单栏可暂停、恢复或退出，暂停状态会保存。
- 每秒通过配置的本地代理向 https://www.google.com/ 发送 HEAD 请求，要求 HTTP 200；请求失败、超时或延迟超过 800ms 即测速。
- 仅支持 Clash Party 全局模式。只在同订阅、同国家或地区内选择不超过 800ms 的最快节点；没有合格节点保持原选择。
- 成功切换后冷却 5 秒，并关闭经过原节点与 GLOBAL 的旧连接，促使应用重连。
- 无法确认节点来源或地区时不切换；规则／直连模式只监测、不自动切换。无需另开控制端口。
- 监控日志位于 ~/Library/Logs/ChatGPT Proxy/monitor.jsonl，超过 5MB 自动轮转。


主窗口齿轮、菜单栏“设置…”或 ⌘, 可打开设置窗口。“开机自启动”使用系统登录项注册，开启后在“系统设置 → 通用 → 登录项与扩展 → 登录时打开”中显示 ChatGPT Proxy。登录启动仅驻留菜单栏；手动启动显示主窗口。首次安装默认不注册，状态以系统实际设置为准。

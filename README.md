# ChatGPT Proxy

适用于 macOS 14 及以上版本的启动器，可将 OpenAI 桌面应用的流量转发到用户指定的本地 SOCKS5 代理。默认上游代理端口为 `7890`。

启动器不会修改 macOS 系统代理设置，而是在 `127.0.0.1:17890` 运行本地 TCP 中继。内置的 ProxyBridge 配置会匹配 `com.openai.*`、旧版 `com.openai.chat`、`ChatGPT`、`codex`、`codex-code-mode-host`、`codex_chronicle*` 和 `org.sparkle-project.*`，并将匹配的流量转发到中继。启动器托管 ProxyBridge 4.1.0 CLI，通过标准输入加载内置规则，确认规则完整生效后才允许启动 GPT。无需打开 ProxyBridge 窗口或修改其偏好文件。启动 GPT 时同时将其 Electron HTTP(S)/WebSocket 代理指向内部 SOCKS5 中继，让域名在代理端解析，避免本地 DNS 无回包导致界面离线；本机和 192.168.*.* 仍绕过该代理。首次运行需在 macOS 批准网络扩展；其他 CLI 实例须先自行停止。关闭窗口后继续驻留，正常退出时先停止 CLI 再关闭中继。

启动器还会为 ChatGPT 及其原生 Codex 子进程设置大小写 `HTTP_PROXY`、`HTTPS_PROXY` 和 `ALL_PROXY`，统一指向 `socks5h://127.0.0.1:17890`，让原生账户、工作区路由和模型请求也由代理端解析域名，避免 `workspace routing discovery timed out`。大小写 `NO_PROXY` 统一保留本机和 `192.168.0.0/16` 直连，其他继承的环境变量保留。更新启动器后，需通过它重新启动 ChatGPT 才会应用这些设置。

启动器要求使用支持 Codex 的新版 ChatGPT 桌面客户端；检测到旧版 `com.openai.chat` 客户端时，会提示更新。

规则也会代理其他路径下的同名 Codex 程序，以及其他应用的 Sparkle 更新器。`localhost`、`127.0.0.1`、`::1` 和 `192.168.*.*` 的 TCP 连接保留直连；其余匹配的 TCP/UDP 连接通过代理。通用工具进程（如 curl、git、Python）不在匹配列表中。

“打开 .codex”按钮可打开当前用户的 Codex 配置目录；目录不存在时会自动创建。

## 构建

需要 Xcode 16 或更高版本。

```sh
make verify
```

构建后的应用位于 `build/ChatGPT Proxy.app`，分发文件为 `dist/ChatGPT-Proxy-2.2.3-Universal.zip`。ZIP 只包含 ChatGPT Proxy；解压后将应用放入 `/Applications`。不包含 ChatGPT、ProxyBridge 或它们的安装包。

应用检测 ProxyBridge 是否安装完整且版本为 4.1.0；不满足时，状态行显示“修复”。点击后通过设置中的本地 SOCKS5 代理在线下载固定版本官方安装包，校验 SHA-256 与签名团队，再通过 macOS 命令行安装器安装。管理员认证由系统完成；成功后自动重新检测并启用代理，不自动打开或重启 GPT。下载失败请检查本地代理设置，可重试；没有直连回退。版本正确但扩展待授权时，使用网络扩展设置入口完成授权。

本项目未配置 Apple Developer ID 证书，启动器采用临时签名。在其他 Mac 上首次打开时，可能需要在“隐私与安全性”中允许运行。下载安装的 ProxyBridge 保留官方签名。历史统一安装包移至 `build/legacy-distributions`。


后台监控与自动切换：
- 打开应用即监控，关闭窗口后继续驻留菜单栏；菜单栏可暂停、恢复或退出，暂停状态会保存。
- 每秒通过配置的本地代理向 https://www.google.com/ 发送 HEAD 请求，要求 HTTP 200；请求失败、超时或延迟超过 800ms 即测速。
- 仅支持 Clash Party 全局模式，自动切换始终限制在同一订阅内。先测试当前地区全部节点；没有合格节点时，按设置中已勾选备用地区从上到下依次测速，选择首个可用地区中不超过 800ms 的最快节点。所有候选地区均无合格节点时保持原选择，后续继续监控重试。
- 设置中可勾选备用地区并用上下按钮调整优先级，设置自动保存。地区来自当前订阅实际可选节点；首次发现默认不勾选，已保存但暂时没有节点的地区保留并跳过。当前地区始终优先测试，健康时不会主动回切；测速途中修改地区设置会放弃本轮切换。
- 成功切换后冷却 5 秒，并关闭经过原节点与 GLOBAL 的旧连接，促使应用重连。
- 无法确认节点来源或地区时不切换；规则／直连模式只监测、不自动切换。无需另开控制端口。
- 监控日志位于 ~/Library/Logs/ChatGPT Proxy/monitor.jsonl，超过 5MB 自动轮转。


主窗口齿轮、菜单栏“设置…”或 ⌘, 可打开设置窗口。“开机自启动”使用系统登录项注册，开启后在“系统设置 → 通用 → 登录项与扩展 → 登录时打开”中显示 ChatGPT Proxy。登录启动仅驻留菜单栏；手动启动显示主窗口。首次安装默认不注册，状态以系统实际设置为准。

设置中的“外观 → 颜色主题”支持跟随系统（默认），以及参考 [VS Code 内置主题](https://github.com/microsoft/vscode/tree/main/extensions) 的 Dark Modern、Light Modern、Monokai 和 Solarized Dark 配色。主题立即应用到主窗口、设置窗口和首次配置面板，并自动保存；选择“跟随系统”可恢复 macOS 外观。

ProxyBridge 活动日志位于 `~/Library/Logs/ChatGPT Proxy/proxybridge.log`，达到 5 MB 轮转。主窗口可查看日志、取消下载或启用；修复入口通过命令行安装器及 macOS 原生管理员认证完成。

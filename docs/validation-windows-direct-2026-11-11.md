# DIRECT 自动恢复 Windows 验证（2026-11-11）

在远程 Windows 测试机 `alex@192.168.100.123` 的独立目录 `C:\Users\alex\gptProxy-direct-20261111`，对本次工作区代码执行 `scripts/verify-windows.ps1`，最终返回成功，退出码为 0。

源代码 ZIP 的本地与远程 SHA-256 一致：`354f577b5ee935181d4de9fa34eb44a82802d6db2f8f0fadf1e4fdf59ddc980b`。工具链为 Rust 1.99.1、.NET SDK 10.0.403、Visual Studio 2022 Build Tools 17.14.25 和 Python 3.14.2。

| 验证项目 | 结果 |
| --- | --- |
| Rust 单元测试 | 37 项通过，含 DIRECT 首轮触发、识别范围及订阅筛选 |
| C# 原生绑定测试 | 10 项通过，含 DIRECT 当前订阅候选筛选 |
| SOCKS/TLS 原生 ABI 场景 | 10 项通过 |
| IPv4/IPv6 TCP/UDP DNS 场景 | 5 项通过 |
| Windows WPF 应用及后台服务 | 自包含 Release 发布成功 |

首次构建因 SSH 会话继承的 HTTP_PROXY / HTTPS_PROXY 指向未监听的 127.0.0.1:7890，导致 NuGet 漏洞数据请求失败（NU1900）。仅清除测试会话中的这两个变量后，原验证脚本通过；没有关闭漏洞审计或更改项目依赖。

构建产物位于远程测试目录的 `build\windows\app`；原始记录为同目录下的 `windows-validation.log`，本机副本保存在 `build/validation/windows-direct-20261111/windows-validation.log`。

本轮执行自动化测试和构建，未覆盖安装应用、启用保护或改动真实 Clash 选择；不包含真实桌面切换或特权 WFP 联调。

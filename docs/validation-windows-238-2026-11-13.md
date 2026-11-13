# 2.3.8 全平台大配置验证（2026-11-13）

发布源代码为 `v2.3.8`，提交 `ef207dabd4a14744d5b075875305123181fdbee0`。macOS 和 Windows 的配置文件及共享核心订阅来源读取上限均为 32 MiB；Windows 控制接口响应上限为 128 MiB，恢复记录上限为 256 MiB。

在 `alex@192.168.100.123` 的独立目录 `C:\Users\alex\gptProxy-release-238-20261113` 运行 `scripts/verify-windows.ps1` 和 `scripts/package-windows.ps1 -SkipBuild`，均成功。源代码 ZIP 的两端 SHA-256 一致：`90f897ff3a415f7f45d91124a7838c0b792f3e5a73aadad632826890e62be79c`。

- Rust：38 项测试通过。
- C#：16 项测试通过，包括 10 MiB、恰好 32 MiB、超限一个字节、无效 UTF-8、BOM、超限恢复记录保留、大配置转换和恢复加载。
- 原生 SOCKS/TLS：10 个场景通过。
- 双栈 DNS：5 个场景通过。
- WPF 应用、后台服务、自包含运行时和 Inno Setup 安装器构建成功，安装器版本为 2.3.8。
- macOS：164 项 Swift 测试、38 项 Rust 测试、Universal 构建、签名及 ZIP 校验通过。

SSH 会话中仅临时将用户 `.cargo/bin` 和 `.dotnet` 加入 PATH，并清除会话代理变量；未更改系统环境或安装配置。验证日志保存在远程目录的 `windows-validation.log`，本机副本为 `build/validation/windows-238-20261113/windows-validation.log`。

本轮没有覆盖安装测试机现有应用，没有修改实际 Clash 配置、系统 DNS 或 WFP 策略，没有重启 Windows；不代表已完成真实桌面安装升级和特权保护联调。

GitHub Actions 也从同一标签独立构建：[发布构建](https://github.com/lzl51230/gptProxy/actions/runs/43360542891)。初次 CI 的测试和安装器编译已成功，但 Inno Setup 版本字段带末尾空格，导致最后的版本字符串检查失败；工作流现已修正为去掉首尾空白后比较，真实 Windows 安装器验证通过。

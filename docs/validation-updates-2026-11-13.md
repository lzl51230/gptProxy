# 应用内更新验证（2026-11-13）

实现基于本项目的 SwiftUI / WPF / Rust 分层；Windows 更新事务代码参考同机 HerdrContinue 的更新实现，并适配 SOCKS5、便携目录、共享资产选择和保护恢复。

## 已执行

- Rust 更新选择测试：2 项通过，覆盖数字版本、预发布、平台缺包与相同版本。
- Swift 更新测试：4 项通过，覆盖下载前拒绝非法协议/端口、缺失清单、外部资产来源与 440 点宽设置面板渲染。
- .NET 更新测试：8 项通过，覆盖版本、路径、显式代理无绕过、ZIP 越界路径、并发检查取消及 UAC 1223 取消错误。Windows 全量 27 项通过。
- Windows App、Service、Updater 在 Windows 11 / .NET SDK 10.0.403 上锁定依赖构建、发布和便携 ZIP 打包通过，无警告。修复 Updater 的 RuntimeIdentifier 锁文件及 Windows PowerShell 5.1 打包兼容性。
- macOS 隔离辅助程序测试：实际替换至 2.4.0、启动失败回滚至 2.3.9、目标目录缺失时恢复旧版。使用临时签名模拟应用，没有替换用户安装或操作系统 DNS。
- `make verify` 已通过 Rust 40 项、Swift 168 项全量测试、Universal 构建、签名、分发 ZIP 验证。最后的界面通知转发修正另通过 4 项更新测试，并重新打包。
- 本机日志：`/tmp/gptproxy-update-delivery-verify.log`、`/tmp/gptproxy-update-ui-final.log`、`/tmp/gptproxy-update-package-final.log`。

## Windows 实机验收

在 `192.168.100.123` 的独立测试目录执行；未替换正式安装。测试使用普通桌面权限，必要时走系统原生 UAC。

- Rust 40 项、真实网络 ABI 心跳 10 项、DNS 5 项测试通过。
- 更新器真实文件事务：成功安装、启动失败回滚、进程中断后恢复、取消保留旧版均通过；保留 `Data/settings.json` 和用户额外文件。
- 完整 WPF 更新流程：2.3.9 → 2.4.0、SHA-256 损坏包拒绝、启动失败回滚通过。
- `Program Files` 隔离目录：允许 UAC 后升级成功；取消 UAC 后保留旧版。新版 GUI 仍以普通用户权限运行。
- 五套主题、五类页面或状态、150% / 200% 缩放及繁忙控件检查通过。实测发现托盘关闭时 Deactivated 重入 Close，已修复并重跑通过。
- 实际 GitHub 检查经配置的 SOCKS5 7890 成功；`NO_PROXY=*` 不绕过指定代理；无效代理端口失败且不直连回退。
- ChatGPT 运行中完整升级通过：11 个进程的 PID / 启动时间完全一致，设置 SHA-256 未变，2.4.0 GUI 非管理员，保护已恢复。正常退出后系统 DNS 和 Clash 配置哈希与测试前一致；临时服务、恢复记录、测试进程和计划任务均已清理。原有 ProxyBridge GUI 已恢复打开。
- 运行中验收发现暂停监控的状态文案仍显示“保护未启用”，已修正恢复分支，使其明确显示“节点自动切换已暂停”，并在实机用例中断言暂停状态。验收脚本同时等待定时刷新结束，避免读取旧界面状态误报失败。
- GUI 升级使用仅 Debug 编译的本地 HTTP fixture，覆盖正式下载后的校验、解压、替换、重启与健康确认。Release 构建不包含测试入口。未发布虚拟 2.4.0 GitHub Release。

复现入口：`scripts/qa-update-worker-windows.py`、`scripts/qa-updates-windows.ps1 -PrepareFixtures -Case success-stopped`。后者要求已完成 Windows 构建与便携打包；运行中用例使用 `-Case success-running`，需实际 ChatGPT 和桌面会话。

## macOS 实机验收

在本机独立应用目录测试，正式 `/Applications/ChatGPT Proxy.app` 未替换，实际 ChatGPT 保持运行。Debug 验收入口使用本地发布 fixture；Release 不包含入口或本地下载替换。测试参数通过进程内 UserDefaults 参数域覆盖，保存的正式偏好设置保持不变。

- 只读父目录触发更新器原生管理员授权。允许后真实替换至 2.4.0，重启应用的 UID 仍为 501；取消后保留 2.3.9 并显示“操作已被取消”。
- 实机暴露异步更新任务调用 AppKit 退出时重复等待异步清理的问题。更新准备完成后标记可立即退出，避免再次进入异步清理；更新和恢复路径都按主队列调度退出。
- 实机暴露配套 DNS 辅助程序变化时，后台维护无法请求安装授权的问题。更新重启改走显式保护恢复路径，必要时请求原生授权，恢复后更新状态文案；不调用 ChatGPT 重启逻辑。
- 运行中升级通过：升级前真实 DNS 保护已启用，新版安装配套辅助程序后恢复保护，监控暂停状态保留，ChatGPT PID 71979 与启动时间不变，保存的偏好设置未变。测试应用正常清理退出后 DNS 回到 disabled/restored。
- 使用生产下载器相同 curl 参数检查实际 GitHub：SOCKS5 7890 成功，`NO_PROXY=*` 不绕过代理，无效代理端口返回连接错误，没有直连回退。
- 修复后 Swift 全量 168 项测试通过。初次测试缺少 Xcode `DEVELOPER_DIR` 导致 XCTest 模块不可用，修正构建环境后通过。
- 复现入口：`scripts/qa-updates-macos.py`，支持 `authorization`、`cancel`、`running`、`stopped`。先构建 arm64 / x86_64 Debug 应用和 Release 资源。脚本及时回收旧应用进程，避免僵尸进程影响辅助程序的退出判定。原生安全授权由用户亲自完成。
- 最终复验 `running-a980d5fa` 通过，界面明确显示“更新已完成；保护已恢复”。已逐字节恢复原 DNS 辅助程序和 launchd 配置；DNS、Clash 配置及正式偏好设置与基线一致，测试应用、更新器和 CLI 子进程均已退出。系统恢复对比见 `cleanup.json`。
- 修复后重新生成 Universal Release ZIP，SHA-256、ZIP CRC、清单、双架构和代码签名验证均通过；确认三个分发可执行文件不包含 Debug QA 环境变量入口。
- 证据位于 `dist/qa/macos-updates/`。允许授权：`authorization-4a38dace`；取消：`cancel-627e89ec`；真实保护恢复：`running-3cdbb1c7`。修复前退出挂起、辅助程序不匹配及脚本竞态记录保留，不计入通过项。

## 尚未覆盖的线上场景

- 未发布测试 GitHub Release，未验证生产高版本的完整在线升级；实际网络检查与本地完整升级分别验证。


## 证据与构建产物

- 本地证据目录：`dist/qa/windows-updates/evidence/`，含各场景结果、更新前后截图、事务阶段和构建日志；准备阶段取消、ProxyBridge 冲突及旧验收脚本刷新竞态的失败记录也保留，不计入成功验收。
- 运行中最终复验记录：`gptproxy-qa-success-running-3847ffd7/result.json`（含暂停状态断言）；首次成功记录：`gptproxy-qa-success-running-b14a38a8/result.json`；系统恢复对比：`cleanup.json`。
- Windows 便携包及 SHA-256：`dist/qa/windows-updates/artifacts/`。已核对下载后 SHA-256、ZIP CRC 和清单中全部 756 个文件。
- macOS 最新便携包及校验文件：`dist/ChatGPT-Proxy-2.3.9-Universal.zip` 和同名 `.sha256`。
- 上述实机验收在发布前完成，2.4.0 当时为隔离 fixture。正式发布准备将两平台版本统一为 2.4.0，并从提交对应的源码重新构建分发包。

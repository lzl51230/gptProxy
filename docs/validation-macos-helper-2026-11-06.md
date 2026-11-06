# macOS helper 特权网络验收（2026-11-06）

## 最终结果

已将实际安装的 root LaunchDaemon 从协议 2 升级为协议 3，并将 `/Applications/ChatGPT Proxy.app` 更新为与 helper 匹配的最终构建。helper 与应用内附带文件逐字节一致，代码签名检查通过。服务使用用户 501，Clash Party 内核为 Mihomo v1.19.24。

真实网络验证覆盖：

- 启用后，系统解析器指向 `127.0.0.1` 与 `::1`；IPv4/IPv6 TCP/UDP 四条本机 DNS 路径可用，A 查询有答案，AAAA 查询为空。
- Clash IPv6 策略关闭；PF anchor 包含 IPv4 和 IPv6 外部 TCP/UDP 53 阻断规则；恢复记录由 root 持有，权限为 0600。
- IPv4 使用 `1.1.1.1`，IPv6 使用 Windows 测试机的局域网链路本地 DNS 对端。两者 TCP/UDP 均先验证可达，启用后被阻断，关闭后重新可达。
- 正常关闭保护后，全部网络服务的 DNS 配置、PF 启用状态与 anchor、Clash IPv6 与节点选择均与测试前基线一致，恢复记录删除。
- 强制结束独立测试启动器后，watchdog 自动恢复；同样逐项比对 DNS、PF、Clash 与恢复记录。
- 强制结束 helper 后，launchd 自动重新启动并从持久记录恢复。`launchctl` 确认新 PID、运行次数 2、上次终止信号 9；恢复后的所有基线断言通过。

测试结束时 helper 为 disabled，DNS 保护关闭。启动器后台监控恢复测试前的开启状态，因此此后允许其按原策略自动选择节点。未重启本机 Mac。

## 联调发现与修复

Clash 配置重载返回成功后，订阅节点可能尚未加载。立即恢复原选择会收到 HTTP 400 `proxy not exist`。新增 Rust 共用判断 `clashSelectionsReady`，两端重载后均有界等待目标节点进入选择器；恢复事务持久记录选择是否已成功应用，避免失败回滚把重载期间的临时默认节点当作用户选择。

共享核心新增两项回归测试：异步订阅节点就绪，以及中断启用时保留原选择／已启用后保留用户的新选择。Swift 的真实 Unix HTTP fixture 模拟重载后的延迟节点加载，并拒绝过早选择。最终 30 项 Rust、144 项 Swift 测试通过，更新后的三项 Clash transport 测试另行通过。

另一次 DNS 就绪失败来自外部配置覆盖。临时控制接口跟踪只记录方法、路径与调用进程，没有记录配置请求体；确认 `Herdr Auto Continue` 发起了额外的 `PUT /configs`。用户暂停其他相关任务后，配置保持稳定，完整特权测试通过。跟踪结束后已恢复原 Unix 控制接口。保护期间不应由两个配置管理程序同时重载 Clash；发生覆盖时启动器会拒绝就绪或恢复原网络设置。

## 测试脚本清理说明

网络与恢复断言均已完成，包括 helper 崩溃恢复后的 PF、DNS、Clash 与记录检查。随后测试脚本等待自身测试子进程响应 SIGTERM 时超时，导致脚本最终退出码非零；该测试进程已按确切 PID 用 SIGKILL 清理，并再次确认 helper 为 disabled、DNS 与 Clash 基线一致。测试脚本的清理逻辑也已修正。此问题属于测试进程清理，不是产品恢复失败；没有把该脚本报告成零退出码通过。

本地证据位于忽略版本控制的 `build/macos-privileged-qa/`：`acceptance.json`、`progress.log`、`root-trace.log`、`provider-regression.log`、`verify.log`。helper 原文件、LaunchDaemon plist 与旧应用 ZIP 均有备份。

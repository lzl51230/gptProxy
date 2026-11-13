# 2.3.9 Windows 便携版验证（2026-11-13）

在 `alex@192.168.100.123` 的 Windows 11 x64 真机上验证。用户选择 ZIP 便携分发，同时保留完整 DNS/WFP 保护：启用时授权后台恢复组件，恢复成功并退出后清理。Windows 不再生成 Inno Setup 安装器。全平台配置读取上限仍为每个文件 32 MiB。

## 构建与回归

- 远程 `scripts/verify-windows.ps1`：38 项 Rust、19 项 C#、10 个 SOCKS/TLS 场景、5 个双栈 DNS 场景通过；WPF、服务和 ZIP 打包成功。
- 新增便携身份测试覆盖 PID/启动时间、消失的进程、启动器路径和文件哈希变化。
- macOS `scripts/verify.sh`：164 项 Swift、38 项 Rust 测试、Universal 构建、签名和解压包校验通过。

## 真机验证

- ZIP 解压到带空格目录，以普通交互用户运行。后台组件使用管理员会话执行同一启动脚本；本轮未手动点击安全桌面的 UAC 确认框。
- 从旧安装版恢复并迁移服务成功。便携设置位于同目录 `Data/settings.json`，临时服务从受保护的 ProgramData 缓存运行。
- 实际 Clash 工作配置为 9,615,490 字节，超过旧 4 MiB 限制。启用、正常 ChatGPT 重启确认和 Codex 长连接 `maintaining` 状态通过。
- 保护期间 IPv4/IPv6 回环 TCP/UDP DNS 可用，AAAA 策略检查通过，外部 IPv4 TCP/UDP 明文 DNS 被 WFP 阻断。
- 强制结束后台服务：SCM 自动重启，恢复原 DNS 和 Clash 设置，恢复记录删除；启动器仍可再次启用保护。
- 强制结束已启用保护的便携启动器：DNS 恢复、代理 CLI 退出、临时服务注销、运行缓存与恢复记录删除。空闲启动器异常退出也完成相同清理。
- 未知版本 999 的专用测试恢复记录：状态为失败，启动器退出后服务和原记录仍保留。仅在确认哈希一致后删除该测试夹具，再验证正常清理；未删除真实恢复记录。
- 完成恢复后移动整个便携目录：设置哈希不变，新路径下重新启用、ChatGPT 重启和长连接监控成功。
- 真实托盘菜单“恢复 DNS 并退出”：启动器、代理 CLI、临时服务退出，缓存和恢复记录删除。
- 每次恢复后，所有网卡 DNS 地址与会话开始时快照一致；Clash 恢复全局模式、IPv6 开启、TUN 关闭和原节点选择。

证据保存在远程 `C:\Users\alex\gptProxy-live-238-20261113`，包括 `portable-enabled.json`、`portable-dns-wfp.json`、`service-crash-recovery.json`、`active-owner-crash-cleanup.json`、`unknown-journal-retention.json`、`portable-move.json`、`moved-portable-enabled.json`、`normal-tray-exit.json`。原配置和恢复快照含用户数据，仅留在测试机，不纳入版本库或发布包。

## 联调修复

旧版 `--shutdown` 会等待所有同名启动器，导致迁移时等待新便携启动器。改为确认旧路径启动器已退出，再调用旧版恢复、停止和删除旧服务。

缓存最初只允许 SYSTEM/Administrators 读取；服务模拟普通用户处理命名管道请求时，.NET 延迟加载运行时程序集失败。缓存现在仅授予会话所有者读取/执行权限，写入仍仅限 SYSTEM/Administrators。恢复目录和记录保持 SYSTEM/Administrators 专有访问。

## 验证边界

本轮没有重启整机、断电或测试网卡热插拔。服务启动时恢复、启动器死亡和服务崩溃路径已实测，不能代替便携版完整的开机前登录恢复测试。IPv6 外部 DNS 阻断曾在 2.3.3 的真实局域网对端上验证，本轮重测双栈回环和 IPv4 外部阻断。

此前 2.3.8 安装器可在测试机成功覆盖安装，但 Authenticode 状态为 NotSigned；用户看到的认证提示不等于安装逻辑失败。改为 ZIP 后无需安装器，EXE 仍无可信发布者签名，Windows 仍可能显示信誉或未知发布者提示。

import ChatGPTProxyCore
import SwiftUI

struct ContentView: View {
    @Environment(\.selectedAppTheme) private var theme
    @ObservedObject var model: AppModel
    @State private var presentedIssue: StatusIssue?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            statusSection
            Divider()
            MonitorStatusView(monitor: model.monitor)
            actionSection
        }
        .padding(28)
        .task {
            await model.refreshStatus()
        }
        .sheet(isPresented: $model.showingSetup) {
            SetupView(model: model)
                .appTheme()
        }
        .alert(item: $presentedIssue) { issue in
            Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                primaryButton: .default(Text(issue.actionTitle)) {
                    perform(issue.action)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("ChatGPT Proxy")
                    .font(.title2.weight(.semibold))
                Text(model.phase.message)
                    .font(.callout)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .help("设置…")
                .accessibilityLabel("设置")
            Button {
                Task { await model.refreshStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新检测")
            .disabled(model.isBusy)
        }
    }

    private var statusSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            statusRow(
                "ChatGPT",
                ready: model.chatGPTInstalled,
                detail: model.chatGPTInstalled ? "已安装新版" : model.chatGPTNeedsUpdate ? "需要更新" : "未安装",
                issue: .chatGPT(requiresUpdate: model.chatGPTNeedsUpdate)
            )
            statusRow(
                "ProxyBridge",
                ready: model.proxyBridgeInstalled,
                detail: model.proxyBridgeInstalled ? "已安装" : "未安装",
                issue: .proxyBridge
            )
            statusRow(
                "网络扩展",
                ready: model.extensionEnabled,
                detail: model.extensionEnabled ? "已启用" : "未启用",
                issue: .networkExtension
            )
            statusRow(
                "专用配置",
                ready: model.proxyBridgeProfileReady,
                detail: model.proxyBridgeProfileReady ? "已启用" : "未启用",
                issue: .dedicatedProfile(
                    manualFallback: model.profileInstallRequiresManualFallback
                )
            )
            statusRow(
                "本地代理",
                ready: model.localProxyReady,
                detail: proxyDetail,
                issue: .localProxy(
                    port: model.proxyPort,
                    egressLocation: model.egressLocation
                )
            )
        }
    }

    private var actionSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    Task { await model.launchChatGPT() }
                } label: {
                    Label("启动 ChatGPT", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy)

                Button {
                    model.openCodexDirectory()
                } label: {
                    Label("打开 .codex", systemImage: "folder")
                }
                .controlSize(.large)
            }

            HStack {
                Button("首次配置") {
                    model.showingSetup = true
                }
                Button("打开 ProxyBridge") {
                    model.openProxyBridge()
                }
                Spacer()
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .buttonStyle(.link)
        }
    }

    private func statusRow(
        _ title: String,
        ready: Bool,
        detail: String,
        issue: StatusIssue
    ) -> some View {
        GridRow {
            Group {
                if ready {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        presentedIssue = issue
                    } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("查看处理方法")
                    .accessibilityLabel("\(title)检查未通过，查看处理方法")
                    .disabled(model.isBusy)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .fontWeight(.medium)
                .frame(width: 100, alignment: .leading)
            Text(detail)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
        }
    }

    private func perform(_ action: RemediationAction) {
        switch action {
        case .downloadChatGPT:
            model.openChatGPTDownload()
        case .installProxyBridge:
            model.openBundledProxyBridgeInstaller()
        case .openNetworkExtensionSettings:
            model.openNetworkExtensionSettings()
        case .installProfile:
            Task { await model.installAndActivateBundledProfile() }
        case .revealProfile:
            model.revealBundledProfile()
        case .refreshStatus:
            Task { await model.refreshStatus() }
        }
    }

    private var proxyDetail: String {
        guard model.proxyReachable else { return "不可用" }
        let udp = model.supportsUDP ? "UDP 可用" : "仅 TCP"
        return "出口 \(model.egressLocation ?? "未知") · \(udp)"
    }

    private var statusColor: Color {
        switch model.phase {
        case .ready:
            .green
        case .failed:
            .red
        default:
            theme.secondary
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var login: LaunchAtLoginController
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    var body: some View {
        ScrollView {
            Form {
                Section("外观") {
                    Picker("颜色主题", selection: $theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text("配色参考 VS Code。选择后立即应用，并在下次启动时保留。")
                        .font(.caption).foregroundStyle(theme.secondary)
                }
                Section("启动") {
                    Toggle("开机自启动", isOn: Binding(
                        get: { login.isEnabled },
                        set: { enabled in Task { await login.setEnabled(enabled) } }
                    ))
                    .toggleStyle(.switch)
                    .disabled(login.isWorking)
                    Text("登录 macOS 后在菜单栏运行，不自动打开主窗口。")
                        .font(.caption).foregroundStyle(theme.secondary)
                    Text(login.statusText).font(.caption)
                    if let error = login.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Button("打开登录项与扩展") { login.openSystemSettings() }
                }
                RegionSettingsView(monitor: model.monitor)
                Section("代理") {
                    TextField("代理端口", value: $model.proxyPort, format: .number.grouping(.never))
                        .disabled(model.isBusy)
                    Button("重新检测") {
                        Task { await model.refreshStatus() }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
        .frame(height: 640)
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
}

private struct RegionSettingsView: View {
    @Environment(\.selectedAppTheme) private var theme
    @ObservedObject var monitor: AutoSwitchMonitor

    var body: some View {
        Section("Clash 备用地区") {
            Text("当前地区始终优先测试；备用地区从上到下依次测试，选择首个可用地区的最快节点。未勾选时仅在当前地区内切换。")
                .font(.caption).foregroundStyle(theme.secondary)
            if monitor.regions.isEmpty {
                Text("尚未发现地区，请连接 Clash Party 后刷新。")
                    .font(.caption).foregroundStyle(theme.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(monitor.regions.enumerated()), id: \.element.id) { index, region in
                            HStack {
                                Toggle(region.name, isOn: Binding(
                                    get: { region.isEnabled },
                                    set: { monitor.setRegionEnabled(region.code, enabled: $0) }
                                ))
                                .toggleStyle(.checkbox)
                                Spacer()
                                Text(availability(region.code))
                                    .font(.caption).foregroundStyle(theme.secondary)
                                Button { monitor.moveRegion(region.code, offset: -1) } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .disabled(index == 0)
                                .help("提高优先级")
                                .accessibilityLabel("提高\(region.name)优先级")
                                Button { monitor.moveRegion(region.code, offset: 1) } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .disabled(index == monitor.regions.count - 1)
                                .help("降低优先级")
                                .accessibilityLabel("降低\(region.name)优先级")
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(height: min(CGFloat(monitor.regions.count) * 36 + 8, 220))
            }
            if let message = monitor.regionCatalogStatus {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            Button(monitor.isRefreshingRegions ? "正在刷新…" : "刷新地区") {
                Task { await monitor.refreshRegions() }
            }
            .disabled(monitor.isRefreshingRegions)
        }
        .task { await monitor.refreshRegions() }
    }

    private func availability(_ code: String) -> String {
        if monitor.regionCatalogStatus != nil { return "未能确认节点" }
        let count = monitor.regionNodeCounts[code, default: 0]
        return count == 0 ? "当前无节点" : "\(count) 个节点"
    }
}

private struct SetupView: View {
    @Environment(\.selectedAppTheme) private var theme
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("首次配置")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭")
            }

            setupRow(number: 1, title: "安装 ProxyBridge") {
                model.openBundledProxyBridgeInstaller()
            }
            setupRow(number: 2, title: "打开并允许网络扩展") {
                model.openProxyBridge()
            }
            setupRow(number: 3, title: "导入 ChatGPT 专用配置") {
                model.revealBundledProfile()
            }

            if !model.chatGPTInstalled {
                Divider()
                Button {
                    model.openChatGPTDownload()
                } label: {
                    Label(
                        model.chatGPTNeedsUpdate ? "更新官方 ChatGPT" : "下载官方 ChatGPT",
                        systemImage: "arrow.down.circle"
                    )
                }
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    private func setupRow(number: Int, title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 28, height: 28)
                .background(.quaternary, in: Circle())
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                Image(systemName: number == 1 ? "shippingbox" : number == 2 ? "network" : "doc.badge.arrow.up")
            }
            .help(title)
        }
    }
}

private struct MonitorStatusView: View {
    @Environment(\.selectedAppTheme) private var theme
    @ObservedObject var monitor: AutoSwitchMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("后台监控").font(.headline)
                Spacer()
                Button(monitor.paused ? "恢复" : "暂停") { monitor.togglePaused() }
            }
            Text(monitor.status)
            Text(monitor.currentNode).font(.caption).textSelection(.enabled)
            if let latency = monitor.latency { Text("Google HEAD · \(latency)ms").monospacedDigit() }
            Text(monitor.lastSwitch).font(.caption).foregroundStyle(theme.secondary)
        }
    }
}

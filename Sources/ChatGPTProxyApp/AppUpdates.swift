import SwiftUI
import AppKit
import ChatGPTProxyCore

@MainActor
final class AppUpdates: ObservableObject {
    @Published var status = "尚未检查更新"
    @Published var release: AppUpdateRelease?
    @Published var busy = false
    @Published var installing = false
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.4.0" }
    func start(model: AppModel) {
        var restart = false
        var restartOutcome = "更新已完成"
#if DEBUG
        let automated = AppUpdateQA.enabled
#else
        let automated = false
#endif
        if !automated {
        timer = Task { [weak self, weak model] in
            while !Task.isCancelled {
                guard let self, let model else { return }
                self.check(port: model.proxyPort)
                do { try await Task.sleep(for: .seconds(21600)) } catch { return }
            }
        }
        }
        recoverPending(model: model)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--update-restart"), args.indices.contains(index+1) {
            let file = URL(fileURLWithPath: args[index+1]).standardizedFileURL
            if file.path.hasPrefix(AppUpdate.cache.path + "/"),
               let data = try? Data(contentsOf: file), let tx = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
               tx["target"] as? String == Bundle.main.bundlePath,
               FileManager.default.fileExists(atPath: file.path + ".commit") {
                restart = true
                try? Data().write(to: URL(fileURLWithPath: file.path + ".healthy"), options: .atomic)
                restartOutcome = (try? String(contentsOfFile:file.path+".phase",encoding:.utf8)) == "rolled-back" ? "更新失败，已恢复旧版" : "更新已完成"
                status = restartOutcome + "；正在恢复原保护状态"
            }
        }
        Task {
            if restart {
                await model.resumeProtectionAfterUpdate()
                status = restartOutcome + (model.protectionPaused ? "；原保护暂停状态已保留" :
                    model.dns.status.isEnabled ? "；保护已恢复" : "；保护恢复待处理：" + model.phase.message)
            }
#if DEBUG
            if AppUpdateQA.enabled { await AppUpdateQA.run(updates: self, model: model) }
#endif
        }
    }
    private func recoverPending(model: AppModel) {
        let fm=FileManager.default
        guard let directories=try? fm.contentsOfDirectory(at:AppUpdate.cache,includingPropertiesForKeys:nil) else {return}
        for dir in directories {
            let file=dir.appendingPathComponent("transaction.json")
            guard !CommandLine.arguments.contains(file.path),
                  let data=try? Data(contentsOf:file), var tx=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  tx["target"] as? String == Bundle.main.bundlePath,
                  fm.fileExists(atPath:Bundle.main.bundlePath+".update-backup") else {continue}
            if let pidString=try? String(contentsOfFile:file.path+".coordinator",encoding:.utf8),let pid=Int32(pidString),kill(pid,0)==0 {continue}
            busy=true;installing=true;status="正在恢复未完成更新…"
            task=Task {
                do {
                    for suffix in [".ready",".commit",".healthy",".installed",".abort",".error"] {try? fm.removeItem(atPath:file.path+suffix)}
                    tx["parent"]=ProcessInfo.processInfo.processIdentifier
                    try JSONSerialization.data(withJSONObject:tx).write(to:file,options:.atomic)
                    try Data().write(to:URL(fileURLWithPath:file.path+".recover"))
                    let helper=dir.appendingPathComponent("AppUpdater")
                    let process=Process();process.executableURL=helper;process.arguments=["coordinate",file.path];try process.run()
                    let deadline=Date().addingTimeInterval(300)
                    while !fm.fileExists(atPath:file.path+".ready") {
                        guard process.isRunning,Date()<deadline else {throw CocoaError(.fileWriteUnknown)}
                        try await Task.sleep(for:.milliseconds(100))
                    }
                    try await model.prepareForUpdate()
                    try Data().write(to:URL(fileURLWithPath:file.path+".commit"))
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return
                } catch {try? Data().write(to:URL(fileURLWithPath:file.path+".abort"));model.resumeAfterFailedUpdate();status="更新恢复失败，备份已保留："+error.localizedDescription}
                busy=false;installing=false
            }
            return
        }
    }
    func check(port: Int) {
        guard !busy else { return }; busy = true; status = "正在通过 SOCKS5 127.0.0.1:\(port) 检查更新…"
        task = Task {
            do {
                let current = Self.version
                let request = Task.detached { try AppUpdate.check(current: current, port: port) }
                release = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
                try Task.checkCancellation()
                status = release.map { "发现新版本 \($0.version)" } ?? "已是最新版本"
            } catch { status = "检查失败：" + error.localizedDescription }
            busy = false
        }
    }
    func stop() { timer?.cancel(); task?.cancel() }
    func cancel() { if !installing { task?.cancel() } }
    func install(model: AppModel) {
        guard !busy, !model.isBusy, let release else { return }
        busy = true; status = "正在下载并校验 \(release.version)…"
        let port = model.proxyPort
        task = Task {
            var transaction: URL?
            do {
                let staging = Task.detached { try AppUpdate.stage(release, port: port, progress: { [weak self] bytes in
                    Task { @MainActor [weak self] in self?.status = "正在下载 \(min(100, bytes * 100 / max(1, release.size)))% · SOCKS5 127.0.0.1:\(port)" }
                }) }
                let stage = try await withTaskCancellationHandler(operation: { try await staging.value }, onCancel: { staging.cancel() })
                try Task.checkCancellation()
                let dir = stage.deletingLastPathComponent(), file = dir.appendingPathComponent("transaction.json")
                transaction = file
                let helper = dir.appendingPathComponent("AppUpdater")
                try FileManager.default.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppUpdater"), to: helper)
                let tx: [String:Any] = ["target":Bundle.main.bundlePath,"stage":stage.path,"version":release.version,"parent":ProcessInfo.processInfo.processIdentifier]
                try JSONSerialization.data(withJSONObject: tx).write(to: file, options: .atomic)
                installing = true; status = "正在准备安装，等待系统授权…"
                let coordinator = Process(); coordinator.executableURL = helper; coordinator.arguments = ["coordinate",file.path]; try coordinator.run()
                let deadline = Date().addingTimeInterval(300)
                while !FileManager.default.fileExists(atPath: file.path + ".ready") {
                    guard coordinator.isRunning, Date() < deadline else { throw CocoaError(.userCancelled) }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try await model.prepareForUpdate()
                try Data().write(to: URL(fileURLWithPath: file.path + ".commit"), options: .atomic)
                // terminate enters a nested AppKit loop. Let this actor task return
                // before the delegate schedules its asynchronous shutdown work.
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            } catch {
                if let transaction { try? Data().write(to: URL(fileURLWithPath: transaction.path + ".abort")) }
                model.resumeAfterFailedUpdate()
                status = "更新未完成：" + error.localizedDescription
            }
            installing = false; busy = false
        }
    }
}
struct AppUpdatePanel: View {
    @ObservedObject var updates: AppUpdates
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            Text("版本 \(AppUpdates.version) · \(updates.status)").font(.caption)
            HStack {
                Button("检查更新") { updates.check(port: model.proxyPort) }.disabled(updates.busy)
                if updates.release != nil { Button("更新并重启") { updates.install(model: model) }.disabled(updates.busy || model.isBusy) }
                if updates.busy && !updates.installing { Button("取消") { updates.cancel() } }
                Link("发布说明", destination: URL(string:"https://github.com/lzl51230/gptProxy/releases/latest")!)
            }
        }
    }
}

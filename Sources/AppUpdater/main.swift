import Foundation
import ChatGPTProxyCore
import Darwin

struct Transaction: Codable {
    var target: String; var stage: String; var version: String; var parent: Int32
}
func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func wait(_ path: String, seconds: Int) throws {
    let deadline = Date().addingTimeInterval(Double(seconds))
    while !FileManager.default.fileExists(atPath: path) {
        if path.hasSuffix(".healthy"), FileManager.default.fileExists(atPath:file+".rollback") {throw CocoaError(.fileWriteUnknown)}
        if FileManager.default.fileExists(atPath: file + ".abort") { throw CocoaError(.userCancelled) }
        if Date() > deadline { throw CocoaError(.fileReadUnknown) }; Thread.sleep(forTimeInterval: 0.1)
    }
}
let args = CommandLine.arguments
if args.count != 3 { exit(2) }
let file = args[2]; let fm = FileManager.default
func mark(_ suffix: String, _ value: String = "") throws { try Data(value.utf8).write(to: URL(fileURLWithPath: file + suffix), options: .atomic) }
do {
    let tx = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    guard tx.target.hasPrefix("/"), tx.target.hasSuffix(".app"), tx.stage.hasPrefix("/"), tx.parent > 1 else { throw CocoaError(.fileReadCorruptFile) }
    let backup = tx.target + ".update-backup", next = tx.target + ".update-next"
    if args[1] == "recover" {
        guard kill(tx.parent,0) != 0, fm.fileExists(atPath: backup) else { throw CocoaError(.fileWriteUnknown) }
        for suffix in [".installed",".healthy",".ready",".rollback",".error",".abort"] { try? fm.removeItem(atPath:file+suffix) }
        try mark(".recover"); try mark(".commit")
        _ = try AppUpdate.run(args[0], ["coordinate",file])
    } else if args[1] == "worker", fm.fileExists(atPath:file+".recover") {
        try mark(".ready"); try wait(file+".commit",seconds:300)
        let deadline=Date().addingTimeInterval(60)
        while kill(tx.parent,0)==0 { if Date()>deadline {throw CocoaError(.fileWriteUnknown)};Thread.sleep(forTimeInterval:0.1) }
        guard fm.fileExists(atPath:backup) else { throw CocoaError(.fileNoSuchFile) }
        _ = try AppUpdate.run("/usr/bin/codesign",["--verify","--deep","--strict",backup])
        if fm.fileExists(atPath:tx.target) { try fm.moveItem(atPath:tx.target,toPath:next+"-failed-"+UUID().uuidString) }
        try fm.moveItem(atPath:backup,toPath:tx.target); try mark(".phase","rolled-back"); try mark(".installed"); try? fm.removeItem(atPath:next)
    } else if args[1] == "worker" {
        guard !fm.fileExists(atPath: backup), !fm.fileExists(atPath: next) else { throw CocoaError(.fileWriteFileExists) }
        defer { if fm.fileExists(atPath:next), !fm.fileExists(atPath:backup) { try? fm.removeItem(atPath:next) } }
        try AppUpdate.validate(URL(fileURLWithPath: tx.stage), version: tx.version)
        _ = try AppUpdate.run("/usr/bin/ditto", [tx.stage,next])
        try AppUpdate.validate(URL(fileURLWithPath: next), version: tx.version)
        try mark(".ready"); try wait(file + ".commit", seconds: 300)
        let deadline = Date().addingTimeInterval(60)
        while kill(tx.parent, 0) == 0 { if Date() > deadline { throw CocoaError(.fileWriteUnknown) }; Thread.sleep(forTimeInterval: 0.1) }
        try mark(".phase", "replacing"); try fm.moveItem(atPath: tx.target, toPath: backup)
        do { try fm.moveItem(atPath: next, toPath: tx.target) }
        catch { try fm.moveItem(atPath: backup, toPath: tx.target); throw error }
        try mark(".installed")
        do { try wait(file + ".healthy", seconds: 60); try mark(".phase", "complete"); try fm.removeItem(atPath: backup) }
        catch {
            // Coordinator terminates the unresponsive replacement before authorizing rollback.
            try wait(file + ".rollback", seconds: 30)
            try fm.moveItem(atPath: tx.target, toPath: next); try fm.moveItem(atPath: backup, toPath: tx.target)
            try mark(".phase", "rolled-back"); try? fm.removeItem(atPath: next)
        }
    } else if args[1] == "coordinate" {
        try mark(".coordinator",String(getpid()))
        let helper = args[0]; let worker = Process()
        let probe = tx.target + ".probe-" + UUID().uuidString
        var writable = false
        do { try fm.createDirectory(atPath: probe, withIntermediateDirectories: false); try fm.removeItem(atPath: probe); writable = true } catch {}
        if writable { worker.executableURL = URL(fileURLWithPath: helper); worker.arguments = ["worker",file] }
        else {
            worker.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let cmd = quote(helper) + " worker " + quote(file)
            worker.arguments = ["-e", "do shell script \"" + cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"]
        }
        try worker.run()
        let installDeadline=Date().addingTimeInterval(360)
        while !fm.fileExists(atPath:file+".installed") {
            guard worker.isRunning, Date()<installDeadline else { throw CocoaError(.fileWriteUnknown) }
            Thread.sleep(forTimeInterval:0.1)
        }
        func launch() throws -> Process {
            let p = Process(); p.executableURL = URL(fileURLWithPath: tx.target + "/Contents/MacOS/ChatGPTProxyLauncher"); p.arguments = ["--update-restart",file]; try p.run(); return p
        }
        if fm.fileExists(atPath:file+".recover") { worker.waitUntilExit(); _ = try launch(); exit(0) }
        var app: Process?
        do {
            app = try launch(); let deadline=Date().addingTimeInterval(60)
            while !fm.fileExists(atPath:file+".healthy") {
                guard app?.isRunning==true,Date()<deadline else {throw CocoaError(.fileReadUnknown)}
                Thread.sleep(forTimeInterval:0.1)
            }
        }
        catch { if let app, app.isRunning { app.terminate(); Thread.sleep(forTimeInterval: 2); if app.isRunning { kill(app.processIdentifier,SIGKILL) } }; try mark(".rollback") }
        worker.waitUntilExit()
        let phase = try? String(contentsOfFile: file + ".phase", encoding: .utf8)
        if phase == "rolled-back" { _ = try launch() }
        if phase == "complete", URL(fileURLWithPath:tx.stage).deletingLastPathComponent() == URL(fileURLWithPath:file).deletingLastPathComponent() {
            try? fm.removeItem(atPath:tx.stage)
            try? fm.removeItem(at:URL(fileURLWithPath:file).deletingLastPathComponent().appendingPathComponent("download.zip"))
        }
    } else { exit(2) }
} catch { try? mark(".error", error.localizedDescription); exit(1) }

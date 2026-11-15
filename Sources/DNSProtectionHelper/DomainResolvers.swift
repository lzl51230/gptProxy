import Darwin
import Foundation
import ChatGPTProxyCore

struct DomainResolvers {
    private let domains: [String]
    private let marker: Data
    private let directory: URL
    private let staging: URL

    init(journal: [String: Any],
         directory: URL = URL(fileURLWithPath: "/etc/resolver"),
         state: URL = URL(fileURLWithPath: DNSProtectionConfiguration.stateDirectory)) throws {
        guard let id = journal["dnsTransaction"] as? String, UUID(uuidString: id) != nil,
              let domains = journal["domains"] as? [String], !domains.isEmpty,
              domains.allSatisfy({ $0.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil })
        else { throw MonitorError.message("域名 DNS 恢复记录无效") }
        self.domains = domains
        self.directory = directory
        self.staging = state.appendingPathComponent("resolver-\(id)")
        self.marker = Data("# ChatGPT Proxy \(id)\nnameserver 127.0.0.1\nport 17853\n".utf8)
    }

    // Do not follow a replacement symlink or write through a user-writable directory.
    private func directoryExists() throws -> Bool {
        var st = stat()
        if lstat(directory.path, &st) != 0 {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid(), st.st_mode & 0o022 == 0 else {
            throw MonitorError.message("DNS resolver 目录权限不安全：\(directory.path)")
        }
        return true
    }

    private func overlap(_ candidate: String) -> String? {
        let name = candidate.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.first { name == $0 || name.hasSuffix("." + $0) || $0.hasSuffix("." + name) }
    }

    func checkFiles() throws {
        guard try directoryExists() else { return }
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            if let domain = overlap(file) { throw MonitorError.message("域名 \(domain) 与已有 resolver 文件 \(file) 冲突") }
        }
    }

    // scutil prints one block per resolver, including supplemental VPN resolvers.
    func checkEffective(_ output: String, installed: Bool) throws {
        var seen = Set<String>()
        for block in output.components(separatedBy: "resolver #").dropFirst() {
            var domain = "", port = "", servers: [String] = []
            for line in block.split(separator: "\n") {
                let field = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard field.count == 2 else { continue }
                if field[0] == "domain" { domain = field[1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                if field[0] == "port" { port = field[1] }
                if field[0].hasPrefix("nameserver[") { servers.append(field[1]) }
            }
            guard !domain.isEmpty, let affected = overlap(domain) else { continue }
            guard installed, domains.contains(domain), servers == ["127.0.0.1"], port == "17853" else {
                throw MonitorError.message("域名 \(affected) 与系统解析规则 \(domain) 冲突")
            }
            seen.insert(domain)
        }
        if installed, let missing = domains.first(where: { !seen.contains($0) }) {
            throw MonitorError.message("系统尚未加载 \(missing) 的 DNS 规则")
        }
    }

    func install() throws {
        if try !directoryExists() {
            guard mkdir(directory.path, 0o755) == 0 || errno == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard try directoryExists() else { throw MonitorError.message("resolver 目录不可用") }
        // Publish complete files exclusively. A crash between link and unlink leaves
        // a journaled staging name and a complete, identifiable final file.
        for domain in domains {
            try marker.write(to: staging, options: .atomic)
            let path = directory.appendingPathComponent(domain).path
            guard chmod(staging.path, 0o644) == 0, link(staging.path, path) == 0 else {
                throw MonitorError.message("无法安装 \(domain) 的 resolver：\(String(cString: strerror(errno)))")
            }
            try FileManager.default.removeItem(at: staging)
        }
    }

    private func owns(_ file: URL) throws -> Bool {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT || errno == ELOOP { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(.EIO) }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == geteuid(), st.st_size == marker.count else { return false }
        return try handle.read(upToCount: marker.count + 1) == marker
    }

    func verifyFiles() throws {
        guard try directoryExists() else { throw MonitorError.message("resolver 目录已移除") }
        for domain in domains {
            guard try owns(directory.appendingPathComponent(domain)) else {
                throw MonitorError.message("域名 \(domain) 的 resolver 已被修改")
            }
        }
    }

    func restore() throws {
        if try owns(staging) { try FileManager.default.removeItem(at: staging) }
        guard try directoryExists() else { return }
        for domain in domains {
            let file = directory.appendingPathComponent(domain)
            if try owns(file) { try FileManager.default.removeItem(at: file) }
        }
    }
}

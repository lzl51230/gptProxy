import Foundation
import Darwin

public enum DNSProtectionIPC {
    public static let maximumMessageSize = 4 * 1024 * 1024

    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw MonitorError.message("辅助服务地址过长")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    public static func send<T: Encodable>(_ value: T, descriptor: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        guard data.count <= maximumMessageSize else { throw MonitorError.message("DNS 配置超过 4 MB") }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard count > 0 else { throw MonitorError.message("DNS 辅助服务连接已关闭") }
            offset += count
        }
    }

    public static func receive<T: Decodable>(_ type: T.Type, descriptor: Int32) throws -> T {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < maximumMessageSize {
            let count = Darwin.recv(descriptor, &buffer, min(buffer.count, maximumMessageSize - data.count), 0)
            guard count > 0 else { throw MonitorError.message("DNS 辅助服务未响应") }
            if let newline = buffer.prefix(count).firstIndex(of: 10) {
                data.append(contentsOf: buffer.prefix(newline))
                return try JSONDecoder().decode(type, from: data)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw MonitorError.message("DNS 辅助服务消息超过限制")
    }

    public static func configure(_ descriptor: Int32, seconds: Int = 45) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func request(_ request: DNSProtectionRequest) async throws -> DNSProtectionStatus {
        try await Task.detached(priority: .utility) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw MonitorError.message("无法连接 DNS 辅助服务") }
            defer { close(fd) }
            configure(fd)
            var address = try address(DNSProtectionConfiguration.socketPath)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw MonitorError.message("DNS 辅助服务尚未安装或未运行") }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else {
                throw MonitorError.message("DNS 辅助服务身份验证失败")
            }
            try send(request, descriptor: fd)
            return try receive(DNSProtectionStatus.self, descriptor: fd)
        }.value
    }
}

public enum DNSPacket {
    public static func query(name: String, type: UInt16 = 1, id: UInt16 = .random(in: 0...UInt16.max)) -> Data {
        let bytes: [UInt8] = (try? RustCore().call(["op":"dnsQuery", "name":name, "type":type, "id":id])) ?? []
        return Data(bytes)
    }
    public static func isValidResponse(_ response: Data, to query: Data) -> Bool {
        (try? RustCore().call(["op":"dnsValid", "response":Array(response), "query":Array(query)])) ?? false
    }
    public static func probe(port: UInt16, timeout: Int = 5, tcp: Bool = false, host: String = "127.0.0.1") throws {
        let _: Bool = try RustCore().call(["op":"dnsProbe", "port":port, "timeout":timeout, "tcp":tcp, "host":host])
    }
    public static func assertIPv4Responses(a: Data, aQuery: Data, aaaa: Data, aaaaQuery: Data) throws {
        let _: Bool = try RustCore().call(["op":"dnsAssertIPv4", "a":Array(a), "aQuery":Array(aQuery), "aaaa":Array(aaaa), "aaaaQuery":Array(aaaaQuery)])
    }
    public static func probeIPv4Only(port: UInt16) throws {
        let _: Bool = try RustCore().call(["op":"dnsProbe", "port":port, "ipv4Only":true])
    }
}

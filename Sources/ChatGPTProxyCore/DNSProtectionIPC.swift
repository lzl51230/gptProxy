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
        var data = Data([UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in name.split(separator: ".") {
            data.append(UInt8(label.utf8.count)); data.append(contentsOf: label.utf8)
        }
        data.append(contentsOf: [0, UInt8(type >> 8), UInt8(type & 255), 0, 1])
        return data
    }

    public static func isValidResponse(_ response: Data, to query: Data) -> Bool {
        guard query.count >= 12, response.count >= query.count,
              response.prefix(2) == query.prefix(2), response[2] & 0x80 != 0,
              response[2] & 0x02 == 0, [0, 3].contains(response[3] & 0x0f),
              response[4] == 0, response[5] == 1 else { return false }
        return response[12..<query.count] == query[12...]
    }

    public static func probe(port: UInt16, timeout: Int = 5, tcp: Bool = false, host: String = "127.0.0.1") throws {
        let query = query(name: "gptproxy-\(UUID().uuidString.lowercased()).example.com")
        let ipv6 = host.contains(":")
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard fd >= 0 else { throw MonitorError.message("无法创建 DNS 检测连接") }
        defer { close(fd) }
        DNSProtectionIPC.configure(fd, seconds: timeout)
        let result: Int32
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian; inet_pton(AF_INET6, host, &address.sin6_addr)
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian; inet_pton(AF_INET, host, &address.sin_addr)
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard result == 0 else { throw MonitorError.message("DNS 入口不可达") }
        var payload = query
        if tcp { payload = Data([UInt8(query.count >> 8), UInt8(query.count & 255)]) + query }
        var sent = 0
        while sent < payload.count {
            let count = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: sent), payload.count - sent, 0) }
            guard count > 0 else { throw MonitorError.message("DNS 检测发送失败") }
            sent += count
        }
        func read(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                var buffer = [UInt8](repeating: 0, count: count - result.count)
                let received = recv(fd, &buffer, buffer.count, 0)
                guard received > 0 else { throw MonitorError.message("代理内 DNS 查询超时或连接关闭") }
                result.append(contentsOf: buffer.prefix(received))
            }
            return result
        }
        let response: Data
        if tcp {
            let size = try read(2)
            response = try read(Int(size[0]) << 8 | Int(size[1]))
        } else {
            var buffer = [UInt8](repeating: 0, count: 65535)
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { throw MonitorError.message("代理内 DNS 查询超时") }
            response = Data(buffer.prefix(count))
        }
        guard isValidResponse(response, to: query) else { throw MonitorError.message("代理内 DNS 返回无效响应") }
    }
}

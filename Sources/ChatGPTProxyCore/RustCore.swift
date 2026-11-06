import Foundation
import CRustProxy

/// Owns the Rust handle and all returned memory. Callers never retain FFI buffers.
public final class RustCore: @unchecked Sendable {
    private let handle: OpaquePointer
    public init() {
        precondition(cgp_core_abi_version() == 1, "Unsupported Rust core ABI")
        handle = cgp_core_create()!
    }
    deinit { cgp_core_destroy(handle) }
    public func call<T: Decodable>(_ request: [String: Any], as: T.Type = T.self) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: request)
        let buffer = data.withUnsafeBytes { cgp_core_call(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        defer { cgp_core_buffer_free(buffer) }
        let result = try JSONDecoder().decode(Response<T>.self, from: Data(bytes: buffer.data!, count: buffer.len))
        guard result.ok, let value = result.value else { throw RustError.message(result.error ?? "Rust core returned no result") }
        return value
    }
    public func nullable<T: Decodable>(_ request: [String: Any], as: T.Type = T.self) throws -> T? {
        let data = try JSONSerialization.data(withJSONObject: request)
        let buffer = data.withUnsafeBytes { cgp_core_call(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        defer { cgp_core_buffer_free(buffer) }
        let result = try JSONDecoder().decode(Response<T>.self, from: Data(bytes: buffer.data!, count: buffer.len))
        guard result.ok else { throw RustError.message(result.error ?? "Rust core failed") }
        return result.value
    }
    public func object(_ request: [String: Any]) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: request)
        let buffer = data.withUnsafeBytes { cgp_core_call(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        defer { cgp_core_buffer_free(buffer) }
        guard let response = try JSONSerialization.jsonObject(with: Data(bytes: buffer.data!, count: buffer.len)) as? [String:Any] else {
            throw RustError.message("Shared workflow response is invalid")
        }
        guard response["ok"] as? Bool == true, let value = response["value"] else {
            throw RustError.message(response["error"] as? String ?? "Shared workflow request failed")
        }
        return value
    }
    private struct Response<T: Decodable>: Decodable { let ok: Bool; let value: T?; let error: String? }
}
private enum RustError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}

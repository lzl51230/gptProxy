import XCTest
import Darwin
@testable import ChatGPTProxyCore

final class ClashDNSClientTests: XCTestCase, @unchecked Sendable {
    func testRuntimeReloadUsesPayloadAndOnlyRestoresManualSelectors() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.stop() }
        let client = ClashControllerClient()
        let selection = try await client.selection(socket: fixture.socket)
        XCTAssertEqual(selection, ["GLOBAL": "auto"])
        let yaml = "mode: global\ndns:\n  nameserver: ['https://1.1.1.1/dns-query#GLOBAL']\n"
        try await client.reload(socket: fixture.socket, yaml: yaml)
        try await client.restoreSelection(socket: fixture.socket, selection: selection)
        try await client.flushDNS(socket: fixture.socket)
        let log = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n")
        let rows = try log.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(rows[0]["path"] as? String, "/configs?force=false")
        XCTAssertEqual((rows[0]["body"] as? [String: String])?["payload"], yaml)
        XCTAssertEqual(rows[1]["path"] as? String, "/proxies/GLOBAL")
        XCTAssertEqual(rows[2]["path"] as? String, "/cache/dns/flush")
    }

    func testRejectedConfigurationDoesNotPassTheActivationGate() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.stop() }
        do {
            try await ClashControllerClient().reload(socket: fixture.socket, yaml: "reject")
            XCTFail("Rejected DNS configuration must fail activation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("控制接口")) }
    }
}

private final class ControllerFixture {
    let process = Process()
    let socket = "/tmp/cgp-dns-\(UUID().uuidString).sock"
    let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    init() throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, socket, log.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        guard output.fileHandleForReading.readData(ofLength: 1) == Data([82]) else { throw CocoaError(.fileReadUnknown) }
    }
    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGTERM); var status: Int32 = 0; _ = waitpid(process.processIdentifier, &status, 0) }
        try? FileManager.default.removeItem(atPath: socket)
        try? FileManager.default.removeItem(at: log)
    }
    static let script = #"""
import socketserver, http.server, json, sys
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  payload={'proxies':{'GLOBAL':{'name':'GLOBAL','type':'Selector','now':'auto','all':['auto']},'auto':{'name':'auto','type':'URLTest','now':'node','all':['node']},'node':{'name':'node','type':'VLESS'}}}
  b=json.dumps(payload).encode(); self.send_response(200); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
 def change(self):
  n=int(self.headers.get('Content-Length',0)); body=json.loads(self.rfile.read(n)) if n else {}
  with open(sys.argv[2],'a') as f: f.write(json.dumps({'path':self.path,'body':body})+'\n')
  self.send_response(400 if body.get('payload')=='reject' else 204); self.send_header('Content-Length','0'); self.end_headers()
 do_PUT=change
 do_POST=change
server=socketserver.UnixStreamServer(sys.argv[1],Handler)
print('R',flush=True)
server.serve_forever()
"""#
}

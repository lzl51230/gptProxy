import XCTest
@testable import ChatGPTProxyCore
final class AppUpdateTests: XCTestCase {
    func testRejectsInsecureDownloadBeforeNetworking() {
        XCTAssertThrowsError(try AppUpdate.download("http://example.com/test", to: URL(fileURLWithPath:"/tmp/never-written"), port:7890))
        XCTAssertThrowsError(try AppUpdate.download("https://example.com/test", to: URL(fileURLWithPath:"/tmp/never-written"), port:0))
    }
    func testMissingManifestCannotInstall() {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try AppUpdate.validate(dir,version:"2.4.0"))
    }
    func testSharedSelectionRejectsForeignAssets() throws {
        let release:[String:Any] = ["tag_name":"v2.4.0","draft":false,"prerelease":false,"assets":[["name":"ChatGPT-Proxy-2.4.0-Universal.zip","size":100,"browser_download_url":"https://example.com/app.zip"]]]
        XCTAssertThrowsError(try RustCore().nullable(["op":"updateRelease","release":release,"current":"2.3.9","platform":"macos"],as:AppUpdateRelease.self))
    }
}

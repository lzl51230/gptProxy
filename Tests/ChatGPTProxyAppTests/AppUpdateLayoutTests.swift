import AppKit
import SwiftUI
import XCTest
@testable import ChatGPTProxyApp
import ChatGPTProxyCore
@MainActor final class AppUpdateLayoutTests: XCTestCase {
    func testUpdateStatesRenderInSettingsWidth() throws {
        let model=AppModel(profileConfigurator:{},refreshAfterProfileConfiguration:{})
        let release=try JSONDecoder().decode(AppUpdateRelease.self,from:Data(#"{"version":"2.4.0","url":"https://github.com/lzl51230/gptProxy/releases/download/v2.4.0/app.zip","size":100,"name":"app.zip"}"#.utf8))
        for state in ["已是最新版本","正在下载 50%","代理连接失败，请检查设置"] {
            model.updates.status=state;model.updates.release=release
            let view=AppUpdatePanel(updates:model.updates,model:model).padding().frame(width:440).background(Color.white)
            let renderer=ImageRenderer(content:view);renderer.scale=1
            let image=try XCTUnwrap(renderer.cgImage);XCTAssertEqual(image.width,440);XCTAssertLessThan(image.height,200)
        }
    }
}

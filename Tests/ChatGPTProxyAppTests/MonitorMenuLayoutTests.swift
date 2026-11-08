import AppKit
import SwiftUI
import XCTest
@testable import ChatGPTProxyApp

@MainActor
final class MonitorMenuLayoutTests: XCTestCase {
    func testStatusRefreshKeepsActionPixelsInPlace() throws {
        let initial = MonitorMenuSnapshot(status: "等待监控", currentNode: "未知", latency: nil,
            connectionSeconds: 0, consecutiveFailures: 0, phase: .stopped,
            disconnectReason: nil, lastSwitch: "尚未切换", paused: false)
        var updated = initial
        updated.status = "Codex 长连接正常"
        updated.currentNode = String(repeating: "🇺🇸 美国洛杉矶 02 | 流媒体 | ", count: 12)
        updated.latency = 279
        updated.connectionSeconds = 419
        updated.consecutiveFailures = 2
        updated.phase = .validating
        updated.disconnectReason = String(repeating: "通过错误关闭连接", count: 15)
        updated.lastSwitch = String(repeating: "日本 → 美国（240ms）", count: 12)

        for theme in AppTheme.allCases {
            let before = try render(initial, theme: theme)
            let after = try render(updated, theme: theme)
            XCTAssertEqual(before.width, 440)
            XCTAssertEqual(before.height, after.height, "Status fields must not resize the panel")
            // The four action rows and bottom padding occupy the final 146 points.
            let actions = CGRect(x: 0, y: before.height - 146, width: 440, height: 146)
            try assertSamePixels(before, after, in: actions)

            var paused = updated
            paused.paused = true
            paused.phase = .paused
            paused.latency = nil
            paused.disconnectReason = nil
            let pausedImage = try render(paused, theme: theme)
            XCTAssertEqual(before.height, pausedImage.height)
            // Only the third action's text changes when pausing.
            for region in [CGRect(x: 0, y: before.height - 146, width: 440, height: 66),
                           CGRect(x: 0, y: before.height - 44, width: 440, height: 44)] {
                try assertSamePixels(before, pausedImage, in: region)
            }
        }
    }

    private func render(_ snapshot: MonitorMenuSnapshot, theme: AppTheme) throws -> CGImage {
        let view = MonitorMenuContent(snapshot: snapshot, showMainWindow: {}, showSettings: {}, togglePaused: {}, quit: {})
            .environment(\.selectedAppTheme, theme)
            .foregroundStyle(theme.foreground)
            .background(theme.background)
            .environment(\.colorScheme, theme.colorScheme ?? .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func assertSamePixels(_ before: CGImage, _ after: CGImage, in region: CGRect,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let lhs = try pixels(before, in: region), rhs = try pixels(after, in: region)
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        // Core Graphics can round antialiased edge colors by one 8-bit step between renders.
        let maximumDifference = zip(lhs, rhs).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumDifference, 1, "Action pixels moved or changed", file: file, line: line)
    }

    private func pixels(_ image: CGImage, in rect: CGRect) throws -> Data {
        let crop = try XCTUnwrap(image.cropping(to: rect))
        let context = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return Data(bytes: try XCTUnwrap(context.data), count: crop.width * crop.height * 4)
    }
}

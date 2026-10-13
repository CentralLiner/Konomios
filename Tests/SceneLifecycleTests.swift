import XCTest
import UIKit
import WebKit
@testable import KonomiTV

final class SceneLifecycleTests: XCTestCase {
    @MainActor
    func testApplicationConnectsBrowserToItsWindowScene() throws {
        // Check the real host app's launch, including Info.plist scene configuration.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
            $0.delegate is SceneDelegate
        })
        let delegate = try XCTUnwrap(scene.delegate as? SceneDelegate)
        let window = try XCTUnwrap(delegate.window)
        let browser = try XCTUnwrap(window.rootViewController as? WebViewController)
        XCTAssertTrue(window.windowScene === scene)
        XCTAssertTrue(browser.isViewLoaded)
        XCTAssertFalse(window.isHidden)
        XCTAssertTrue(browser.view.subviews.flatMap(\.subviews).contains { $0 is WKWebView })
    }
}

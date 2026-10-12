import XCTest
import UIKit
import WebKit
@testable import KonomiTV

final class WebViewLayoutTests: XCTestCase {
    @MainActor
    func testBrowserKeepsHeightWhenFullscreenTemporarilyRemovesIt() throws {
        try withBrowser { browser, webView in
            let container = try XCTUnwrap(webView.superview)
            let original = container.bounds
            XCTAssertGreaterThan(original.height, 500)
            XCTAssertEqual(webView.frame, original)
            XCTAssertTrue(webView.translatesAutoresizingMaskIntoConstraints)
            XCTAssertTrue(container.constraints.allSatisfy {
                ($0.firstItem as? UIView) !== webView && ($0.secondItem as? UIView) !== webView
            })

            // WebKit copies these to a placeholder when transferring the browser to its window.
            let placeholder = UIView(frame: webView.frame)
            placeholder.autoresizingMask = webView.autoresizingMask
            webView.removeFromSuperview()
            container.addSubview(placeholder)
            browser.view.setNeedsLayout()
            browser.view.layoutIfNeeded()
            XCTAssertEqual(container.bounds, original)

            placeholder.removeFromSuperview()
            browser.viewWillAppear(false)
            XCTAssertTrue(webView.superview === container)
            XCTAssertEqual(webView.frame, original)
        }
    }

    @MainActor
    func testBrowserFillsItsContainerAfterRotationWithoutForcedLandscape() throws {
        try withBrowser { browser, webView in
            browser.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
            browser.view.setNeedsLayout()
            browser.view.layoutIfNeeded()
            let container = try XCTUnwrap(webView.superview)
            XCTAssertEqual(webView.frame, container.bounds)
            XCTAssertGreaterThan(webView.frame.width, webView.frame.height)
            XCTAssertTrue(browser.supportedInterfaceOrientations.contains(.portrait))

            browser.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            browser.view.setNeedsLayout()
            browser.view.layoutIfNeeded()
            XCTAssertEqual(webView.frame, container.bounds)
            XCTAssertGreaterThan(webView.frame.height, webView.frame.width)
        }
    }

    @MainActor
    private func withBrowser(_ body: (WebViewController, WKWebView) throws -> Void) throws {
        let suite = "WebViewLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = WebViewController(settings: AppSettings(defaults: defaults))
        browser.loadViewIfNeeded()
        browser.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        browser.view.setNeedsLayout()
        browser.view.layoutIfNeeded()
        let webView = try XCTUnwrap(browser.view.subviews.flatMap(\.subviews).compactMap { $0 as? WKWebView }.first)
        try body(browser, webView)
    }
}

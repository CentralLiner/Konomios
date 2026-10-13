import XCTest
import UIKit
import WebKit
@testable import KonomiTV

final class WebViewLayoutTests: XCTestCase {
    @MainActor
    func testBrowserKeepsTopAndSideSafeAreasAndDrawsThroughBottomInset() throws {
        try withBrowser { browser, webView in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let originalWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.rootViewController = browser
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                originalWindow?.makeKeyAndVisible()
            }
            browser.additionalSafeAreaInsets = UIEdgeInsets(top: 18, left: 31, bottom: 24, right: 13)
            browser.view.setNeedsLayout()
            browser.view.layoutIfNeeded()
            let safeFrame = browser.view.safeAreaLayoutGuide.layoutFrame
            let browserFrame = webView.convert(webView.bounds, to: browser.view)
            let expectedFrame = CGRect(x: safeFrame.minX, y: safeFrame.minY,
                                       width: safeFrame.width,
                                       height: browser.view.bounds.maxY - safeFrame.minY)
            XCTAssertEqual(browserFrame, expectedFrame)
            XCTAssertGreaterThanOrEqual(safeFrame.minX, 31)
            XCTAssertGreaterThanOrEqual(browser.view.bounds.maxY - safeFrame.maxY, 24)
            XCTAssertGreaterThan(browserFrame.maxY, safeFrame.maxY)
        }
    }

    @MainActor
    func testLandscapeButtonKeepsBrowserInPlaceWithoutElementFullscreen() throws {
        try withBrowser { browser, webView in
            let container = try XCTUnwrap(webView.superview)
            XCTAssertFalse(webView.configuration.preferences.isElementFullscreenEnabled)
            browser.bridgeRequestedLandscapeToggle()
            XCTAssertTrue(browser.supportedInterfaceOrientations.contains(.landscapeLeft))
            XCTAssertTrue(browser.supportedInterfaceOrientations.contains(.landscapeRight))
            XCTAssertFalse(browser.supportedInterfaceOrientations.contains(.portrait))
            XCTAssertTrue(browser.prefersStatusBarHidden)
            browser.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
            browser.view.setNeedsLayout()
            browser.view.layoutIfNeeded()
            XCTAssertTrue(webView.superview === container)
            XCTAssertEqual(webView.fullscreenState, .notInFullscreen)
            XCTAssertEqual(webView.frame, container.bounds)
            XCTAssertGreaterThan(webView.frame.width, webView.frame.height)

            browser.bridgeRequestedLandscapeToggle()
            XCTAssertTrue(browser.supportedInterfaceOrientations.contains(.portrait))
            XCTAssertFalse(browser.prefersStatusBarHidden)
            XCTAssertTrue(webView.superview === container)
        }
    }

    @MainActor
    func testLeavingWatchReleasesLandscapeLockWithoutRecreatingTheBrowser() throws {
        try withBrowser { browser, webView in
            let parent = webView.superview
            browser.bridgeRequestedLandscapeToggle()
            browser.bridgeRequestedLandscapeExit()
            browser.bridgeRequestedLandscapeExit()
            XCTAssertTrue(browser.supportedInterfaceOrientations.contains(.portrait))
            XCTAssertTrue(webView.superview === parent)
            XCTAssertEqual(webView.fullscreenState, .notInFullscreen)
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

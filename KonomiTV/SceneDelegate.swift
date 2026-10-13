import UIKit

/// 同じ WebView とプレイヤーを、接続された画面のライフサイクル中保持する。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var browser: WebViewController?
    var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        browser?.supportedInterfaceOrientations ?? .allButUpsideDown
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let browser = WebViewController()
        self.browser = browser
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = browser
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // PiP から戻っても load/reload を呼ばず、同じ Web プレイヤーを維持する。
        browser?.becomeActive()
    }

    func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace,
                     interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
                     traitCollection previousTraitCollection: UITraitCollection) {
        browser?.refreshLayout()
    }
}

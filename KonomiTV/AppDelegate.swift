import UIKit
import AVFAudio

/// WebView の所有者をアプリのライフサイクルに合わせて保持する。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var browser: WebViewController?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let browser = WebViewController()
        self.browser = browser
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        browser?.supportedInterfaceOrientations ?? .allButUpsideDown
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // PiP から戻っても load/reload を呼ばず、同じ Web プレイヤーを維持する。
        browser?.refreshMediaState()
    }
}

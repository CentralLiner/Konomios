import UIKit

/// アプリ全体の設定を行い、画面のライフサイクルは SceneDelegate に委ねる。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if let delegate = window?.windowScene?.delegate as? SceneDelegate {
            return delegate.supportedInterfaceOrientations
        }
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return .allButUpsideDown
    }
}

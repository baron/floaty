import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        windowScene.title = "Floaty Dashboard \(UUID().uuidString.prefix(6))"

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = DashboardViewController(windowBridge: CatalystWindowBridge())
        window.makeKeyAndVisible()
        self.window = window
    }
}

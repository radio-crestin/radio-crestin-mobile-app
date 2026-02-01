import UIKit
import Flutter

@available(iOS 13.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)

        let controller = FlutterViewController(engine: flutterEngine, nibName: nil, bundle: nil)

        // Show the launch screen as a splash until Flutter renders its first frame.
        // FlutterViewController automatically removes the splashScreenView once
        // the first Flutter frame is presented.
        if let launchScreen = UIStoryboard(name: "LaunchScreen", bundle: nil).instantiateInitialViewController()?.view {
            controller.splashScreenView = launchScreen
        }

        window?.rootViewController = controller
        window?.makeKeyAndVisible()
    }
}

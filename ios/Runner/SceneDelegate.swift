import UIKit
import Flutter

@available(iOS 13.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate, FlutterSceneLifeCycleProvider {
    var window: UIWindow?

    /// Forwards scene events to plugins. With scenes, iOS delivers URL opens
    /// (radiocrestin://, universal links) and user activities to the scene
    /// delegate instead of the app delegate, so app_links and
    /// firebase_messaging only see them through this forwarding.
    let sceneLifeCycleDelegate = FlutterPluginSceneLifeCycleDelegate()

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

        // The shared engine is created by AppDelegate, outside this scene:
        // register it explicitly (a no-op when already registered) so the
        // cold-start URL or activity in `connectionOptions` reaches plugins.
        sceneLifeCycleDelegate.registerSceneLifeCycle(with: flutterEngine)
        sceneLifeCycleDelegate.scene(scene, willConnectTo: session, options: connectionOptions)

        // Cold-start via quick action: forward the shortcut to AppDelegate
        // so the quick_actions plugin can deliver it once the Dart channel is ready
        if let shortcutItem = connectionOptions.shortcutItem {
            let appDelegate = UIApplication.shared.delegate as? AppDelegate
            appDelegate?.application(
                UIApplication.shared,
                performActionFor: shortcutItem,
                completionHandler: { _ in }
            )
        }
    }

    // Warm-start: a radiocrestin:// link opened while the app is running.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        sceneLifeCycleDelegate.scene(scene, openURLContexts: URLContexts)
    }

    // Warm-start: a universal link (https://asculta.radiocrestin.ro/<slug>).
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        sceneLifeCycleDelegate.scene(scene, continue: userActivity)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        sceneLifeCycleDelegate.sceneDidDisconnect(scene)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        sceneLifeCycleDelegate.sceneWillEnterForeground(scene)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        sceneLifeCycleDelegate.sceneDidBecomeActive(scene)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        sceneLifeCycleDelegate.sceneWillResignActive(scene)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        sceneLifeCycleDelegate.sceneDidEnterBackground(scene)
    }

    // Warm-start: app was in background, user tapped a quick action shortcut
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        appDelegate?.application(
            UIApplication.shared,
            performActionFor: shortcutItem,
            completionHandler: completionHandler
        )
    }
}

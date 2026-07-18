// AppDelegate — the wezig iOS shell app entry point (spec build-mobile-shell,
// story 1). A minimal UIApplicationDelegate whose root view controller is the
// `WKWebViewShellController` (the URL-field + back/forward chrome over the mobile
// `Renderer`/`ChromeSurface` seams). The window + controller are retained here for
// the app's lifetime, so a background→foreground round-trip keeps the same live
// WKWebView (host-only state restoration, ADR-0010 — the native webview persists
// its own page/scroll/history).
//
// Simulator only: no signing, no Apple Developer account.

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    // Retained for the app's lifetime so the hosted WKWebView survives
    // background/foreground (host-only page-state restoration).
    private var shellController: WKWebViewShellController?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = WKWebViewShellController()
        shellController = controller
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

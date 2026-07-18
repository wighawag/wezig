// The wezig iOS shell (toolchain proof): a minimal app that hosts one WKWebView
// and calls into the wezig Zig static library over the C-ABI (bridging header
// `wezig_mobile.h`). This proves Zig↔Swift linkage and a live WebView on the
// iOS Simulator; it is NOT a full app (no chrome, no navigation UI yet — those
// arrive with the downstream mobile renderer/embedding tasks).

import UIKit
import WebKit

// The root view controller: one full-screen WKWebView, loading HTML that embeds
// the greeting returned by the Zig core — so a successful launch VISIBLY proves
// the Zig lib is linked and callable.
final class RootViewController: UIViewController {
    private var webView: WKWebView!

    override func loadView() {
        webView = WKWebView(frame: .zero)
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Call the Zig C-ABI: version integer + greeting string.
        let abi = wezig_abi_version()
        let greeting = String(cString: wezig_greeting())
        NSLog("wezig: linked Zig core abi=\(abi) greeting=\"\(greeting)\"")

        let html = """
        <!doctype html><html><head><meta name="viewport" \
        content="width=device-width, initial-scale=1"></head>
        <body style="font-family:-apple-system;padding:2rem">
        <h1>wezig iOS shell</h1>
        <p>Zig core linked — ABI v\(abi)</p>
        <p>\(greeting)</p>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = RootViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

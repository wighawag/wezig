// The wezig iOS script-message BRIDGE proof (spec explore-mobile-shell story 8;
// task mobile-web3-hooks-parity). The iOS twin of the desktop `shell-bridge-test`:
// it round-trips ONE message BOTH ways through the pinned `Renderer` seam over a
// WKWebView, mirroring `window.wezig.ping`.
//
// THIS FILE IS THE ONLY WKWebView/WKUserContentController/WKScriptMessageHandler
// toucher for the bridge proof. The Zig `IosWebviewRenderer` backend drives the
// hook ops (injectUserScript / setScriptMessageHandler / evaluateScript) it
// installs here; the page->native leg flows BACK into the seam via
// `wezig_ios_on_script_message`. The seam decides what the message means; Swift
// only relays — keeping everything above the seam backend-agnostic.
//
// Simulator only: no signing, no Apple Developer account.

import UIKit
import WebKit

// The bridge page: an inline script that calls the injected `window.wezig.ping`
// at load, driving the page->native leg with a known payload (mirrors the
// desktop `bridge_page`).
private let bridgePageHTML = """
<!doctype html><html><head><meta name="viewport" \
content="width=device-width, initial-scale=1"></head>
<body><script>window.wezig.ping('ping-from-page')</script></body></html>
"""

final class BridgeProofCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    var proofCtx: UnsafeMutableRawPointer!

    override init() {
        let config = WKWebViewConfiguration()
        // The WKUserContentController the bridge ops install the user script +
        // message handler onto. Created BEFORE the webview (config is copied at
        // WKWebView init), consistent with the scheme ordering constraint.
        config.userContentController = WKUserContentController()
        webView = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        let wk = Unmanaged.passUnretained(self).toOpaque()
        let viewPtr = Unmanaged.passUnretained(webView).toOpaque()

        // Wire the bridge hook THROUGH the seam: the backend calls these ops to
        // inject the page-world object + open the `wezig` channel.
        proofCtx = wezig_ios_bridge_proof_start(
            wk,
            viewPtr,
            wkInjectUserScript,
            wkEvaluateScript,
            wkSetScriptMessageHandler
        )

        // Navigate the bridge page (the seam set everything up before this).
        let dataURL = "data:text/html;charset=utf-8,"
            + (bridgePageHTML.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        if let url = URL(string: dataURL) {
            webView.load(URLRequest(url: url))
        }
    }

    // WKScriptMessageHandler: the page->native leg. `didReceive` fires on the
    // MAIN queue, so no marshalling is needed — forward straight into the seam.
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let name = message.name
        let body = "\(message.body)"
        name.withCString { np in
            body.withCString { bp in
                wezig_ios_on_script_message(proofCtx, np, bp)
            }
        }
        // Print the verdict once both legs land (the seam tracks both).
        if wezig_ios_bridge_proof_passed(proofCtx) {
            NSLog("PASS: iOS script-message bridge round-tripped a message both ways")
        }
    }

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        // Give the reply leg a beat; if it did not land, fail loudly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !wezig_ios_bridge_proof_passed(self.proofCtx) {
                NSLog("FAIL: iOS bridge proof — one or both legs did not land")
            }
        }
    }
}

// --- bridge hook ops (WKUserContentController / evaluateJavaScript) -----------

private func bridgeCoord(_ wk: UnsafeMutableRawPointer) -> BridgeProofCoordinator {
    return Unmanaged<BridgeProofCoordinator>.fromOpaque(wk).takeUnretainedValue()
}

private func wkInjectUserScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {
    guard let wk = wk, let source = source else { return }
    let js = String(cString: source)
    let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    bridgeCoord(wk).webView.configuration.userContentController.addUserScript(script)
}

private func wkSetScriptMessageHandler(_ wk: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) {
    guard let wk = wk, let name = name else { return }
    let channel = String(cString: name)
    let c = bridgeCoord(wk)
    // Opens `window.webkit.messageHandlers.<channel>` -> `didReceive`.
    c.webView.configuration.userContentController.add(c, name: channel)
}

private func wkEvaluateScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {
    guard let wk = wk, let source = source else { return }
    bridgeCoord(wk).webView.evaluateJavaScript(String(cString: source))
}

// --- App entrypoint ----------------------------------------------------------

private var gBridgeCoordinator: BridgeProofCoordinator?

final class BridgeProofRootViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("wezig: linked Zig core abi=\(wezig_abi_version())")
        let coordinator = BridgeProofCoordinator()
        gBridgeCoordinator = coordinator
        coordinator.start()
        coordinator.webView.frame = view.bounds
        coordinator.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(coordinator.webView)
    }
}

@main
final class BridgeProofAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = BridgeProofRootViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

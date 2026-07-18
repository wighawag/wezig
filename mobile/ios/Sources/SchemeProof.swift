// The wezig iOS custom-SCHEME proof (spec explore-mobile-shell story 9; task
// mobile-web3-hooks-parity). The iOS twin of the desktop `shell-scheme-test`:
// it serves ONE `wezig-test://hello` request from native THROUGH the pinned
// `Renderer` seam over a WKWebView (WKURLSchemeHandler), mirroring the desktop
// proof.
//
// THIS FILE IS THE ONLY WKWebView/WKURLSchemeHandler toucher for the scheme
// proof. It demonstrates the iOS ORDERING CONSTRAINT surfaced at the seam: the
// WKURLSchemeHandler MUST be registered on the WKWebViewConfiguration BEFORE the
// WKWebView is created (WKWebView copies its configuration at init, so a handler
// set afterwards is ignored and the scheme 404s). The seam's `registerScheme`
// op is therefore called while assembling the configuration, before the webview
// exists — see the finding
// (work/notes/findings/ios-wkurlschemehandler-registration-ordering-2026-07-18.md).
//
// Simulator only: no signing, no Apple Developer account.

import UIKit
import WebKit

private let SCHEME = "wezig-test"
private let SCHEME_URI = "wezig-test://hello"

final class SchemeProofCoordinator: NSObject, WKNavigationDelegate {
    var webView: WKWebView!
    var proofCtx: UnsafeMutableRawPointer!

    // The scheme name the seam asked us to serve. Recorded by the
    // `registerScheme` op the seam calls; the WKURLSchemeHandler serves it.
    var registeredScheme: String?

    func start() {
        let wk = Unmanaged.passUnretained(self).toOpaque()

        // ORDERING CONSTRAINT (spec Q5): the seam's `registerScheme` op runs
        // BEFORE the WKWebView is created, so the WKURLSchemeHandler is installed
        // on the config that the webview copies. We build the config, hand the
        // seam a `registerScheme` op that installs the handler on THIS config,
        // and only AFTER the seam has registered do we create the webview.
        let config = WKWebViewConfiguration()
        self.pendingConfig = config

        // wezig_ios_scheme_proof_start calls `registerScheme` synchronously,
        // which installs the WKURLSchemeHandler on `pendingConfig` — all before
        // the webview below exists.
        // The view pointer is filled after webview creation; the seam's story-9
        // proof does not navigate through the ops table, so a placeholder view
        // cookie is fine until we create the real one.
        let placeholderView = Unmanaged.passUnretained(self).toOpaque()
        proofCtx = wezig_ios_scheme_proof_start(wk, placeholderView, wkRegisterScheme)

        // NOW create the webview from the config the handler was installed on.
        webView = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        webView.navigationDelegate = self

        // Navigate the scheme URI; the WKURLSchemeHandler serves it from native.
        if let url = URL(string: SCHEME_URI) {
            webView.load(URLRequest(url: url))
        }
    }

    // The config the WKURLSchemeHandler is installed on BEFORE the webview.
    fileprivate var pendingConfig: WKWebViewConfiguration?
    // The installed handler, retained so it lives for the webview's lifetime
    // (setURLSchemeHandler does not retain it strongly enough on its own here).
    fileprivate var installedHandler: WezigSchemeHandler?

    // The seam confirms render via `.title_changed`; forward the WKWebView title.
    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        if let t = wv.title {
            t.withCString { wezig_ios_scheme_on_title(proofCtx, $0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let t = wv.title { t.withCString { wezig_ios_scheme_on_title(self.proofCtx, $0) } }
            if wezig_ios_scheme_proof_passed(self.proofCtx) {
                NSLog("PASS: iOS custom scheme served a native body that rendered")
            } else {
                NSLog("FAIL: iOS scheme proof — served or rendered check failed")
            }
        }
    }
}

// The WKURLSchemeHandler that serves each request for the registered scheme by
// up-calling the seam (`wezig_ios_serve_scheme`). It holds the coordinator and
// reads its `proofCtx` at serve time (the seam ctx is only known AFTER
// `wezig_ios_scheme_proof_start` returns, which is AFTER the handler is installed
// on the config — the ordering constraint means the handler must be able to see
// the ctx lazily).
final class WezigSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var coordinator: SchemeProofCoordinator?
    init(coordinator: SchemeProofCoordinator) { self.coordinator = coordinator }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let proofCtx = coordinator?.proofCtx else {
            urlSchemeTask.didFailWithError(NSError(domain: "wezig", code: 3))
            return
        }
        guard let url = urlSchemeTask.request.url?.absoluteString else {
            urlSchemeTask.didFailWithError(NSError(domain: "wezig", code: 1))
            return
        }
        var bodyPtr: UnsafePointer<UInt8>? = nil
        var bodyLen: Int = 0
        var ctPtr: UnsafePointer<CChar>? = nil
        let served = url.withCString {
            wezig_ios_serve_scheme(proofCtx, $0, &bodyPtr, &bodyLen, &ctPtr)
        }
        guard served, let bodyPtr = bodyPtr, let ctPtr = ctPtr else {
            urlSchemeTask.didFailWithError(NSError(domain: "wezig", code: 2))
            return
        }
        let data = Data(bytes: bodyPtr, count: bodyLen)
        let contentType = String(cString: ctPtr)
        let response = HTTPURLResponse(
            url: urlSchemeTask.request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

// --- scheme hook op (register the WKURLSchemeHandler on the pending config) ----

private func schemeCoord(_ wk: UnsafeMutableRawPointer) -> SchemeProofCoordinator {
    return Unmanaged<SchemeProofCoordinator>.fromOpaque(wk).takeUnretainedValue()
}

private func wkRegisterScheme(_ wk: UnsafeMutableRawPointer?, _ scheme: UnsafePointer<CChar>?) {
    guard let wk = wk, let scheme = scheme else { return }
    let c = schemeCoord(wk)
    let name = String(cString: scheme)
    c.registeredScheme = name
    // Install the handler on the config BEFORE the webview is created (ordering).
    // The handler reads the seam ctx lazily from the coordinator (it is only
    // known after `wezig_ios_scheme_proof_start` returns).
    let handler = WezigSchemeHandler(coordinator: c)
    c.pendingConfig?.setURLSchemeHandler(handler, forURLScheme: name)
    c.installedHandler = handler
}

// --- App entrypoint ----------------------------------------------------------

private var gSchemeCoordinator: SchemeProofCoordinator?

final class SchemeProofRootViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("wezig: linked Zig core abi=\(wezig_abi_version())")
        let coordinator = SchemeProofCoordinator()
        gSchemeCoordinator = coordinator
        coordinator.start()
        coordinator.webView.frame = view.bounds
        coordinator.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(coordinator.webView)
    }
}

@main
final class SchemeProofAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = SchemeProofRootViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

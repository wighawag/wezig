// The wezig iOS Renderer-backend proof (spec explore-mobile-shell, story 4;
// task ios-renderer-backend-oneshot). This is the iOS twin of the desktop
// `shell-test`: it drives ONE real page through the pinned `Renderer` seam and
// asserts the three story-4 facts — navigate, a `.finished` lifecycle event
// reaching a seam subscriber, and a non-blank `WKWebView.takeSnapshot`.
//
// THIS FILE IS THE ONLY WKWebView/UIKit-webview toucher for the iOS backend.
// It owns the `WKWebView` + its `WKNavigationDelegate`, builds the C-ABI ops
// table the Zig `IosWebviewRenderer` backend drives, and forwards the nav-
// delegate callbacks INTO the seam (via the exported thunks in mobile_abi.zig).
// The seam decides what `.finished` means and hands back the opaque ViewHandle;
// Swift never interprets the seam's events itself — it just relays them and does
// the platform-only snapshot scan. This keeps everything above the seam
// backend-agnostic (the same discipline the desktop chrome follows).
//
// Simulator only: no signing, no Apple Developer account.

import UIKit
import WebKit

// The self-contained page the proof loads: an opaque coloured background + text
// (a `data:` document, no network, deterministic offline), so a correct render
// produces a decisively non-blank snapshot — mirroring the desktop smoke page.
private let proofPageHTML = """
<!doctype html><html><head><meta name="viewport" \
content="width=device-width, initial-scale=1"></head>
<body style="margin:0;background:#204080;color:#ffffff;font:48px -apple-system">
<h1>wezig iOS renderer proof</h1><p>hello, WKWebView</p></body></html>
"""

// The coordinator: owns the WKWebView, is its navigation delegate, and holds the
// opaque proof context the Zig seam handed back. A global keeps it alive for the
// app's lifetime (one proof, the narrowest real case).
final class RendererProofCoordinator: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var proofCtx: UnsafeMutableRawPointer!
    private var finished = false

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    // Build the C-ABI ops table (the WKWebView operations the Zig backend calls),
    // construct the seam backend via `wezig_ios_proof_start`, and let it navigate
    // through the seam. `Unmanaged.passUnretained(self)` is the `wk` cookie every
    // op receives.
    func start() {
        let wk = Unmanaged.passUnretained(self).toOpaque()
        let viewPtr = Unmanaged.passUnretained(webView).toOpaque()

        // The proof page is loaded by `navigate`; encode it as a data: URL so the
        // seam's `navigate(uri)` drives the load (not a raw `loadHTMLString`),
        // proving navigation crosses the seam exactly as the chrome would call it.
        let dataURL = "data:text/html;charset=utf-8,"
            + (proofPageHTML.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")

        proofCtx = wezig_ios_proof_start(
            wk,
            viewPtr,
            wkNavigate,
            wkReload,
            wkStop,
            wkGoBack,
            wkGoForward,
            wkCanGoBack,
            wkCanGoForward,
            wkSetViewportSize,
            wkInjectUserScript,
            wkEvaluateScript,
            dataURL
        )
    }

    // --- WKNavigationDelegate -> seam (forward each callback into the backend) --
    // The backend maps these to the seam's LifecycleEvent union; we only relay.

    func webView(_ wv: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        emitLoadState(0, wv) // started
    }
    func webView(_ wv: WKWebView, didCommit navigation: WKNavigation!) {
        emitLoadState(1, wv) // committed
    }
    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        emitLoadState(2, wv) // finished
        onFinished(wv)
    }
    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        emitLoadState(3, wv) // failed
    }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emitLoadState(3, wv) // failed
    }

    // Relay one load-state change to the seam. The webview's URL is optional (nil
    // very early); pass a C string when present, NULL otherwise — the seam's
    // `uri` is `?[]const u8`, so NULL is the honest early value.
    private func emitLoadState(_ state: Int32, _ wv: WKWebView) {
        if let s = wv.url?.absoluteString {
            s.withCString { wezig_ios_on_load_state(proofCtx, state, $0) }
        } else {
            wezig_ios_on_load_state(proofCtx, state, nil)
        }
    }

    // On the seam's `.finished`, snapshot the view and scan it non-blank — the
    // platform-only half of the story-4 proof (WKWebView.takeSnapshot), reported
    // back into the seam verdict. Guarded so it runs once.
    private func onFinished(_ wv: WKWebView) {
        if finished { return }
        finished = true
        // Give the compositor a beat to present the first frame before snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let cfg = WKSnapshotConfiguration()
            wv.takeSnapshot(with: cfg) { image, error in
                let nonBlank = image.map(Self.imageIsNonBlank) ?? false
                wezig_ios_proof_set_snapshot_non_blank(self.proofCtx, nonBlank)
                let passed = wezig_ios_proof_passed(self.proofCtx)
                if passed {
                    NSLog("PASS: iOS Renderer seam drove one page (finished event + non-blank snapshot)")
                } else {
                    NSLog("FAIL: iOS Renderer proof — finished=\(wezig_ios_proof_passed(self.proofCtx)) snapshot_non_blank=\(nonBlank)")
                }
            }
        }
    }

    // Non-blank == not every pixel is identical (the desktop `scanNonBlank`
    // criterion). A rendered page (coloured background + text) has at least two
    // distinct pixel values; a blank/failed render is a single uniform colour.
    static func imageIsNonBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let width = cg.width, height = cg.height
        if width == 0 || height == 0 { return false }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buf = [UInt8](repeating: 0, count: bytesPerRow * height)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Compare each pixel word to the first; any difference => non-blank.
        let first = buf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        var i = bytesPerPixel
        while i + bytesPerPixel <= buf.count {
            let px = buf.withUnsafeBytes { $0.load(fromByteOffset: i, as: UInt32.self) }
            if px != first { return true }
            i += bytesPerPixel
        }
        return false
    }
}

// --- C-ABI ops table implementations (the WKWebView operations) --------------
// Free functions so they are plain C function pointers. Each recovers the
// coordinator from the `wk` cookie and performs the WKWebView call.

private func coord(_ wk: UnsafeMutableRawPointer) -> RendererProofCoordinator {
    return Unmanaged<RendererProofCoordinator>.fromOpaque(wk).takeUnretainedValue()
}

private func wkNavigate(_ wk: UnsafeMutableRawPointer?, _ uri: UnsafePointer<CChar>?) {
    guard let wk = wk, let uri = uri else { return }
    let s = String(cString: uri)
    guard let url = URL(string: s) else { return }
    coord(wk).webView.load(URLRequest(url: url))
}
private func wkReload(_ wk: UnsafeMutableRawPointer?) {
    guard let wk = wk else { return }
    coord(wk).webView.reload()
}
private func wkStop(_ wk: UnsafeMutableRawPointer?) {
    guard let wk = wk else { return }
    coord(wk).webView.stopLoading()
}
private func wkGoBack(_ wk: UnsafeMutableRawPointer?) {
    guard let wk = wk else { return }
    coord(wk).webView.goBack()
}
private func wkGoForward(_ wk: UnsafeMutableRawPointer?) {
    guard let wk = wk else { return }
    coord(wk).webView.goForward()
}
private func wkCanGoBack(_ wk: UnsafeMutableRawPointer?) -> Bool {
    guard let wk = wk else { return false }
    return coord(wk).webView.canGoBack
}
private func wkCanGoForward(_ wk: UnsafeMutableRawPointer?) -> Bool {
    guard let wk = wk else { return false }
    return coord(wk).webView.canGoForward
}
private func wkSetViewportSize(_ wk: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32) {
    guard let wk = wk else { return }
    coord(wk).webView.frame = CGRect(x: 0, y: 0, width: Int(width), height: Int(height))
}
private func wkInjectUserScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {
    // Bridge-hook wiring is `mobile-web3-hooks-parity`; a no-op keeps the ops
    // table total for the story-4 proof without half-wiring the hook here.
}
private func wkEvaluateScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {
    guard let wk = wk, let source = source else { return }
    coord(wk).webView.evaluateJavaScript(String(cString: source))
}

// --- App entrypoint ----------------------------------------------------------

private var gCoordinator: RendererProofCoordinator?

final class ProofRootViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        // Prove the Zig core is linked (same handshake the toolchain shell does).
        NSLog("wezig: linked Zig core abi=\(wezig_abi_version())")

        let coordinator = RendererProofCoordinator()
        gCoordinator = coordinator
        coordinator.start()

        // Embed the WKWebView's UIView* the seam handed back as the opaque
        // ViewHandle — proving the opaque handle carries the mobile native view
        // (the Q3 decision) rather than Swift reaching for `coordinator.webView`.
        if let raw = wezig_ios_proof_view(coordinator.proofCtx) {
            let seamView = Unmanaged<UIView>.fromOpaque(raw).takeUnretainedValue()
            seamView.frame = view.bounds
            seamView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(seamView)
        }
    }
}

@main
final class ProofAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ProofRootViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

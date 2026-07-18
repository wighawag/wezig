// The wezig iOS ViewHandle-EMBEDDING proof (spec explore-mobile-shell, Q3/story 6;
// task mobile-viewhandle-embedding-proof). This resolves ADR-0007's flagged
// cross-toolkit-embedding spike on iOS: a mobile chrome-surface `embedView`s the
// renderer's WKWebView view — carried across the seam as the OPAQUE ViewHandle —
// and the page shows.
//
// It differs from RendererProof.swift in ONE load-bearing way: the WKWebView's
// view is NOT added to the hierarchy directly. Instead Swift installs an
// `EmbedPlatform` ops table whose `embedView` op adds the handed view to a
// CONTAINER, and the Zig side drives `surface.embedView(renderer.view())`. So
// the view reaches the screen THROUGH the backend-agnostic chrome-surface seam
// (the chrome would call exactly this), and the proof asserts the opaque handle
// carried the WKWebView across a NON-GTK toolkit host.
//
// THIS FILE IS THE ONLY WKWebView/UIKit toucher for the embedding proof: it owns
// the WKWebView + its delegate + the container UIView, implements the embed ops
// (the only place that interprets the opaque handle as a UIView*), and does the
// platform-only snapshot scan. Everything above the seam stays backend-agnostic.
//
// Simulator only: no signing, no Apple Developer account.

import UIKit
import WebKit

// The self-contained page the proof loads: an opaque coloured background + text
// (a `data:` document, offline+deterministic), so a correct render produces a
// decisively non-blank snapshot of the CONTAINER once the view is embedded.
private let embedPageHTML = """
<!doctype html><html><head><meta name="viewport" \
content="width=device-width, initial-scale=1"></head>
<body style="margin:0;background:#204080;color:#ffffff;font:48px -apple-system">
<h1>wezig iOS embedding proof</h1><p>hosted via ChromeSurface.embedView</p></body></html>
"""

// The coordinator: owns the WKWebView + its delegate, the CONTAINER the seam
// embeds into, and the opaque proof context Zig handed back. A global keeps it
// alive for the app's lifetime (one proof, the narrowest real case).
final class EmbeddingProofCoordinator: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    // The content area the mobile chrome-surface embeds the renderer's view into.
    // On desktop this is "below the toolbar"; here it is a plain container the
    // ChromeSurface.embedView op adds the opaque view to.
    let container: UIView
    var proofCtx: UnsafeMutableRawPointer!
    private var finished = false

    override init() {
        let bounds = UIScreen.main.bounds
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: bounds, configuration: config)
        container = UIView(frame: bounds)
        container.backgroundColor = .black
        super.init()
        webView.navigationDelegate = self
    }

    // Build BOTH ops tables (the WKWebView ops the Renderer backend drives, and
    // the EmbedPlatform ops the ChromeSurface drives), construct the two seams via
    // `wezig_ios_embed_proof_start`, which embeds the renderer's view THROUGH the
    // chrome-surface seam and navigates. `Unmanaged.passUnretained(self)` is the
    // cookie every op receives (both `wk` and `embed_host`).
    func start() {
        let cookie = Unmanaged.passUnretained(self).toOpaque()
        let viewPtr = Unmanaged.passUnretained(webView).toOpaque()

        let dataURL = "data:text/html;charset=utf-8,"
            + (embedPageHTML.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")

        proofCtx = wezig_ios_embed_proof_start(
            cookie,
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
            cookie,          // embed_host (same coordinator)
            embedViewOp,
            embedSetUrlText,
            embedSetBackEnabled,
            embedSetForwardEnabled,
            dataURL
        )
    }

    // --- WKNavigationDelegate -> seam (relay each callback into the backend) ---

    func webView(_ wv: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        emitLoadState(0, wv)
    }
    func webView(_ wv: WKWebView, didCommit navigation: WKNavigation!) {
        emitLoadState(1, wv)
    }
    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        emitLoadState(2, wv)
        onFinished()
    }
    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        emitLoadState(3, wv)
    }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emitLoadState(3, wv)
    }

    private func emitLoadState(_ state: Int32, _ wv: WKWebView) {
        if let s = wv.url?.absoluteString {
            s.withCString { wezig_ios_embed_on_load_state(proofCtx, state, $0) }
        } else {
            wezig_ios_embed_on_load_state(proofCtx, state, nil)
        }
    }

    // On `.finished`, prove BOTH facts: (a) the webview was embedded THROUGH the
    // seam (its superview is the container the chrome-surface embedded into), and
    // (b) the page renders non-blank. Guarded so it runs once.
    //
    // We snapshot the WEBVIEW via `WKWebView.takeSnapshot` (WKWebView content is
    // composited out-of-process, so `layer.render` on the container captures a
    // blank layer — the same reason the renderer proof uses takeSnapshot). The
    // embed-through-seam is proven by the superview identity check, so
    // snapshotting the webview (not the container) does not weaken the proof:
    // the view under snapshot is the one the seam hosted.
    private func onFinished() {
        if finished { return }
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // (a) the embed crossed the seam: the webview is now a child of the
            // container the chrome-surface `embedView` op added it to.
            let embeddedInContainer = (self.webView.superview === self.container)
            if !embeddedInContainer {
                NSLog("FAIL: iOS embedding proof — webview superview is not the seam container")
            }
            // (b) the embedded view renders the page non-blank.
            let cfg = WKSnapshotConfiguration()
            self.webView.takeSnapshot(with: cfg) { image, _ in
                let rendered = image.map(Self.imageIsNonBlank) ?? false
                let nonBlank = embeddedInContainer && rendered
                wezig_ios_embed_set_non_blank(self.proofCtx, nonBlank)
                let passed = wezig_ios_embed_proof_passed(self.proofCtx)
                if passed {
                    NSLog("PASS: iOS ChromeSurface embedded the renderer view via the opaque ViewHandle (page shown)")
                } else {
                    NSLog("FAIL: iOS embedding proof — embedded=\(embeddedInContainer) rendered=\(rendered) passed=\(passed)")
                }
            }
        }
    }

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

// --- C-ABI ops table implementations -----------------------------------------
// Free functions so they are plain C function pointers.

private func coord(_ c: UnsafeMutableRawPointer) -> EmbeddingProofCoordinator {
    return Unmanaged<EmbeddingProofCoordinator>.fromOpaque(c).takeUnretainedValue()
}

// --- WKWebView ops (the Renderer backend drives these) -----------------------
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
    // table total for the embedding proof.
}
private func wkEvaluateScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {
    guard let wk = wk, let source = source else { return }
    coord(wk).webView.evaluateJavaScript(String(cString: source))
}

// --- EmbedPlatform ops (the ChromeSurface drives these) ----------------------
// THIS is the only place the opaque ViewHandle is interpreted as a UIView*.

private func embedViewOp(_ host: UnsafeMutableRawPointer?, _ view: UnsafeMutableRawPointer?) {
    guard let host = host, let view = view else { return }
    let c = coord(host)
    // The opaque handle IS the WKWebView's UIView* (what Renderer.view() returned,
    // carried unchanged across the seam). Downcast and add it to the container —
    // the mobile chrome-surface's `embedView`, hosting a foreign view on a
    // NON-GTK toolkit (ADR-0007's spike, resolved).
    let seamView = Unmanaged<UIView>.fromOpaque(view).takeUnretainedValue()
    seamView.frame = c.container.bounds
    seamView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    c.container.addSubview(seamView)
}
private func embedSetUrlText(_ host: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?) {
    // No URL bar in this narrowest-case proof; the widget op is total but inert.
}
private func embedSetBackEnabled(_ host: UnsafeMutableRawPointer?, _ enabled: Bool) {}
private func embedSetForwardEnabled(_ host: UnsafeMutableRawPointer?, _ enabled: Bool) {}

// --- App entrypoint ----------------------------------------------------------

private var gCoordinator: EmbeddingProofCoordinator?

final class EmbedRootViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("wezig: linked Zig core abi=\(wezig_abi_version())")

        let coordinator = EmbeddingProofCoordinator()
        gCoordinator = coordinator

        // Add the CONTAINER to the window. The renderer's view is added INTO the
        // container by the chrome-surface `embedView` op (driven from Zig in
        // `start()`), NOT here — so the view crosses the seam, not a raw addSubview.
        coordinator.container.frame = view.bounds
        coordinator.container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(coordinator.container)

        coordinator.start()
    }
}

@main
final class EmbedAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = EmbedRootViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

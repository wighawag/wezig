// WKWebViewBackend — the SOLE WKWebView/WebKit toucher for the wezig iOS shell
// app (spec build-mobile-shell, stories 1/3/4/5/6). It owns the WKWebView, its
// WKNavigationDelegate, the WKURLSchemeHandler for the trivial marker scheme, and
// the C-ABI ops tables the Zig core drives (WkPlatform + EmbedPlatform). The Zig
// `IosWebviewRenderer` backend is still the sole thing ABOVE the FFI that drives
// the webview — this file is just the platform side of the C-ABI the toolchain
// pinned (ios_webview_renderer.zig's module doc). Everything above the seam
// (the URL field, the toolbar, the navigation logic) stays backend-agnostic and
// NEVER calls WKWebView directly; the controller reaches only the shell C-ABI.
//
// ## The iOS scheme-ordering constraint (finding), honoured here
//
// The WKURLSchemeHandler for the marker scheme MUST be installed on the
// WKWebViewConfiguration BEFORE the WKWebView is created (WKWebView copies its
// config at init; a handler added afterwards is ignored). So `makeConfiguration`
// installs the handler on the config, and only AFTER `wezig_ios_shell_start` has
// registered the scheme through the seam do we create the WKWebView from that
// config. The scheme set is threaded into the config at build time even though
// this shell registers only the trivial `wezig://` marker (no real content).
//
// Simulator only: no signing, no Apple Developer account.

import UIKit
import WebKit

// The trivial marker scheme the shell threads into the config at build time. A
// genuinely-custom name (iOS forbids re-registering http/https/file/data/…), so
// the ordering wiring is exercised without shipping any real scheme content.
let wezigMarkerScheme = "wezig"

// The backend coordinator: owns the WKWebView + delegate + scheme handler, builds
// the two C-ABI ops tables, and relays WKNavigationDelegate callbacks into the
// seam. The controller holds ONE of these; the WKWebView never escapes it except
// as the opaque ViewHandle the seam carries.
final class WKWebViewBackend: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    // The opaque shell context Zig hands back from `wezig_ios_shell_start`; the
    // controller reads it to drive intents and forward lifecycle events.
    var shellCtx: UnsafeMutableRawPointer!
    // The installed scheme handler, retained for the webview's lifetime.
    private var schemeHandler: WezigMarkerSchemeHandler?

    // Build the WKWebViewConfiguration with the marker scheme handler installed
    // BEFORE the webview exists (the ordering constraint), then create the webview
    // from it. The handler reads `shellCtx` LAZILY (it is only known after
    // `wezig_ios_shell_start` returns, which is after the webview is created).
    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        let handler = WezigMarkerSchemeHandler()
        // ORDERING: install the marker scheme handler on the config BEFORE the
        // WKWebView is created. Zig's `registerScheme` op (below) is a no-op for
        // installation because the handler is installed HERE at config-build time;
        // it only records WHICH scheme name to serve. This threads the scheme set
        // into the config at build time (the finding's requirement).
        config.setURLSchemeHandler(handler, forURLScheme: wezigMarkerScheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        self.schemeHandler = handler
        handler.backend = self
    }

    // --- WKNavigationDelegate -> seam (relay each callback into the shell) ------
    // The Zig backend maps these to the seam's LifecycleEvent union; we only relay,
    // and the chrome reflects them into the URL field + Back/Forward sensitivity.

    func webView(_ wv: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        emitLoadState(0, wv) // started
    }
    func webView(_ wv: WKWebView, didCommit navigation: WKNavigation!) {
        emitLoadState(1, wv) // committed
    }
    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        emitLoadState(2, wv) // finished
        if let s = wv.url?.absoluteString {
            s.withCString { wezig_ios_shell_on_uri(shellCtx, $0) }
        }
    }
    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        emitLoadState(3, wv) // failed
    }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emitLoadState(3, wv) // failed
    }

    private func emitLoadState(_ state: Int32, _ wv: WKWebView) {
        guard shellCtx != nil else { return }
        if let s = wv.url?.absoluteString {
            s.withCString { wezig_ios_shell_on_load_state(shellCtx, state, $0) }
        } else {
            wezig_ios_shell_on_load_state(shellCtx, state, nil)
        }
    }

    fileprivate func serveMarker(_ url: String) -> (Data, String)? {
        guard let ctx = shellCtx else { return nil }
        var bodyPtr: UnsafePointer<UInt8>? = nil
        var bodyLen: Int = 0
        var ctPtr: UnsafePointer<CChar>? = nil
        let served = url.withCString {
            wezig_ios_shell_serve_scheme(ctx, $0, &bodyPtr, &bodyLen, &ctPtr)
        }
        guard served, let bodyPtr = bodyPtr, let ctPtr = ctPtr else { return nil }
        return (Data(bytes: bodyPtr, count: bodyLen), String(cString: ctPtr))
    }
}

// The WKURLSchemeHandler that serves the trivial marker scheme by up-calling the
// seam (`wezig_ios_shell_serve_scheme`). Installed on the config BEFORE the
// webview is created; reads the shell ctx lazily from the backend.
final class WezigMarkerSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var backend: WKWebViewBackend?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let backend = backend,
              let url = urlSchemeTask.request.url,
              let served = backend.serveMarker(url.absoluteString)
        else {
            urlSchemeTask.didFailWithError(NSError(domain: "wezig", code: 1))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": served.1])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(served.0)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

// --- C-ABI ops table implementations -----------------------------------------
// Free functions so they are plain C function pointers. Each recovers the backend
// from the `wk`/`host` cookie and performs the WKWebView / hierarchy call. THIS
// is the only place WKWebView is touched.

private func backend(_ p: UnsafeMutableRawPointer) -> WKWebViewBackend {
    return Unmanaged<WKWebViewBackend>.fromOpaque(p).takeUnretainedValue()
}

// --- WKWebView ops (the Renderer backend drives these) -----------------------
func wkNavigate(_ wk: UnsafeMutableRawPointer?, _ uri: UnsafePointer<CChar>?) {
    guard let wk = wk, let uri = uri else { return }
    let s = String(cString: uri)
    guard let url = URL(string: s) else { return }
    backend(wk).webView.load(URLRequest(url: url))
}
func wkReload(_ wk: UnsafeMutableRawPointer?) {
    guard let wk = wk else { return }
    backend(wk).webView.reload()
}
func wkStop(_ wk: UnsafeMutableRawPointer?) {
    guard let wk = wk else { return }
    backend(wk).webView.stopLoading()
}
func wkGoBack(_ wk: UnsafeMutableRawPointer?) {
    guard let wk = wk else { return }
    backend(wk).webView.goBack()
}
func wkGoForward(_ wk: UnsafeMutableRawPointer?) {
    guard let wk = wk else { return }
    backend(wk).webView.goForward()
}
func wkCanGoBack(_ wk: UnsafeMutableRawPointer?) -> Bool {
    guard let wk = wk else { return false }
    return backend(wk).webView.canGoBack
}
func wkCanGoForward(_ wk: UnsafeMutableRawPointer?) -> Bool {
    guard let wk = wk else { return false }
    return backend(wk).webView.canGoForward
}
func wkSetViewportSize(_ wk: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32) {
    // The container's Auto Layout owns the webview frame; the seam's viewport
    // hint is advisory on iOS (the OS lays the view out). No-op keeps the ops
    // table total without fighting the layout system.
}
func wkInjectUserScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {
    guard let wk = wk, let source = source else { return }
    let js = String(cString: source)
    let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    backend(wk).webView.configuration.userContentController.addUserScript(script)
}
func wkEvaluateScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {
    guard let wk = wk, let source = source else { return }
    backend(wk).webView.evaluateJavaScript(String(cString: source))
}
func wkSetScriptMessageHandler(_ wk: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) {
    // The shell registers no page->native channel (web3 hooks are a follow-on);
    // the op is total but inert.
}
func wkRegisterScheme(_ wk: UnsafeMutableRawPointer?, _ scheme: UnsafePointer<CChar>?) {
    // The marker scheme handler is installed on the config at BUILD time (init,
    // before the webview exists — the ordering constraint). This op only confirms
    // the seam registered the scheme name; the handler serves it lazily via the
    // seam. Nothing to install here (installing now would be too late).
}

// --- EmbedPlatform ops (the ChromeSurface drives these) ----------------------
// THIS is the only place the opaque ViewHandle is interpreted as a UIView*.

func embedViewOp(_ host: UnsafeMutableRawPointer?, _ view: UnsafeMutableRawPointer?) {
    guard let host = host, let view = view else { return }
    let controller = Unmanaged<WKWebViewShellController>.fromOpaque(host).takeUnretainedValue()
    // The opaque handle IS the WKWebView's UIView* (what Renderer.view() returned,
    // carried unchanged across the seam). Downcast and add it to the content
    // container — the mobile chrome-surface's `embedView`.
    let seamView = Unmanaged<UIView>.fromOpaque(view).takeUnretainedValue()
    controller.embedContentView(seamView)
}
func embedSetUrlText(_ host: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?) {
    guard let host = host, let text = text else { return }
    let controller = Unmanaged<WKWebViewShellController>.fromOpaque(host).takeUnretainedValue()
    controller.reflectUrlText(String(cString: text))
}
func embedSetBackEnabled(_ host: UnsafeMutableRawPointer?, _ enabled: Bool) {
    guard let host = host else { return }
    let controller = Unmanaged<WKWebViewShellController>.fromOpaque(host).takeUnretainedValue()
    controller.reflectBackEnabled(enabled)
}
func embedSetForwardEnabled(_ host: UnsafeMutableRawPointer?, _ enabled: Bool) {
    guard let host = host else { return }
    let controller = Unmanaged<WKWebViewShellController>.fromOpaque(host).takeUnretainedValue()
    controller.reflectForwardEnabled(enabled)
}

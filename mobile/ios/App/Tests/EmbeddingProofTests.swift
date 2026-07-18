// EmbeddingProofTests — the iOS ViewHandle-EMBEDDING seam proof, FOLDED into the
// real app's XCTest target (spec build-mobile-shell, stories 7/11; ADR-0009's
// Q3/story-6 cross-toolkit-embedding proof). It replaces the standalone
// hand-assembled `EmbeddingProof.swift` + `embedding-proof.sh` spike: the SAME
// assertion, now compiled + linked by the REAL Xcode project (its "Build Zig
// static lib" phase) and run via `xcodebuild test` on an iOS 17 Simulator, the
// exact Android precedent (the seam proofs are instrumented tests in the real
// app module's test target).
//
// It drives the SAME already-exported proof C-ABI (`wezig_ios_embed_proof_*`,
// retained in the real `libwezig_mobile.a`): a mobile chrome-surface `embedView`s
// the renderer's WKWebView view — carried across the seam as the OPAQUE
// ViewHandle — into a CONTAINER, and asserts (a) the webview's superview is the
// seam container (it was hosted THROUGH the seam) AND (b) the page renders
// non-blank (WKWebView.takeSnapshot). This test case is the ONLY WKWebView/UIKit
// toucher for the embedding proof; everything above the seam stays
// backend-agnostic.

import XCTest
import UIKit
import WebKit

private let embedPageHTML = """
<!doctype html><html><head><meta name="viewport" \
content="width=device-width, initial-scale=1"></head>
<body style="margin:0;background:#204080;color:#ffffff;font:48px -apple-system">
<h1>wezig iOS embedding proof</h1><p>hosted via ChromeSurface.embedView</p></body></html>
"""

// The coordinator: owns the WKWebView + its delegate, the CONTAINER the seam
// embeds into, and the opaque proof context Zig handed back. Mirrors the old
// spike coordinator; only the entrypoint (an XCTest expectation) differs.
final class EmbeddingProofCoordinator: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let container: UIView
    var proofCtx: UnsafeMutableRawPointer!
    private var finished = false
    private let done: (Bool, String) -> Void

    init(done: @escaping (Bool, String) -> Void) {
        self.done = done
        let bounds = UIScreen.main.bounds
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: bounds, configuration: config)
        container = UIView(frame: bounds)
        container.backgroundColor = .black
        super.init()
        webView.navigationDelegate = self
    }

    // Build BOTH ops tables + construct the two seams via
    // `wezig_ios_embed_proof_start`, which embeds the renderer's view THROUGH the
    // chrome-surface seam and navigates. The container must already be in a
    // window (the test adds it) so the WKWebView actually renders.
    func start() {
        let cookie = Unmanaged.passUnretained(self).toOpaque()
        let viewPtr = Unmanaged.passUnretained(webView).toOpaque()

        let dataURL = "data:text/html;charset=utf-8,"
            + (embedPageHTML.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")

        proofCtx = wezig_ios_embed_proof_start(
            cookie, viewPtr,
            wkNavigate, wkReload, wkStop, wkGoBack, wkGoForward,
            wkCanGoBack, wkCanGoForward, wkSetViewportSize,
            wkInjectUserScript, wkEvaluateScript,
            cookie,
            embedViewOp, embedSetUrlText, embedSetBackEnabled, embedSetForwardEnabled,
            dataURL)
    }

    func webView(_ wv: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { emitLoadState(0, wv) }
    func webView(_ wv: WKWebView, didCommit navigation: WKNavigation!) { emitLoadState(1, wv) }
    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) { emitLoadState(2, wv); onFinished() }
    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { emitLoadState(3, wv) }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { emitLoadState(3, wv) }

    private func emitLoadState(_ state: Int32, _ wv: WKWebView) {
        if let s = wv.url?.absoluteString {
            s.withCString { wezig_ios_embed_on_load_state(proofCtx, state, $0) }
        } else {
            wezig_ios_embed_on_load_state(proofCtx, state, nil)
        }
    }

    private func onFinished() {
        if finished { return }
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let embeddedInContainer = (self.webView.superview === self.container)
            let cfg = WKSnapshotConfiguration()
            self.webView.takeSnapshot(with: cfg) { image, _ in
                let rendered = image.map(imageIsNonBlank) ?? false
                let nonBlank = embeddedInContainer && rendered
                wezig_ios_embed_set_non_blank(self.proofCtx, nonBlank)
                let passed = wezig_ios_embed_proof_passed(self.proofCtx)
                self.done(passed, "embedded=\(embeddedInContainer) rendered=\(rendered) passed=\(passed)")
            }
        }
    }
}

private func coord(_ c: UnsafeMutableRawPointer) -> EmbeddingProofCoordinator {
    return Unmanaged<EmbeddingProofCoordinator>.fromOpaque(c).takeUnretainedValue()
}

private func wkNavigate(_ wk: UnsafeMutableRawPointer?, _ uri: UnsafePointer<CChar>?) {
    guard let wk = wk, let uri = uri else { return }
    guard let url = URL(string: String(cString: uri)) else { return }
    coord(wk).webView.load(URLRequest(url: url))
}
private func wkReload(_ wk: UnsafeMutableRawPointer?) { guard let wk = wk else { return }; coord(wk).webView.reload() }
private func wkStop(_ wk: UnsafeMutableRawPointer?) { guard let wk = wk else { return }; coord(wk).webView.stopLoading() }
private func wkGoBack(_ wk: UnsafeMutableRawPointer?) { guard let wk = wk else { return }; coord(wk).webView.goBack() }
private func wkGoForward(_ wk: UnsafeMutableRawPointer?) { guard let wk = wk else { return }; coord(wk).webView.goForward() }
private func wkCanGoBack(_ wk: UnsafeMutableRawPointer?) -> Bool { guard let wk = wk else { return false }; return coord(wk).webView.canGoBack }
private func wkCanGoForward(_ wk: UnsafeMutableRawPointer?) -> Bool { guard let wk = wk else { return false }; return coord(wk).webView.canGoForward }
private func wkSetViewportSize(_ wk: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32) {
    guard let wk = wk else { return }
    coord(wk).webView.frame = CGRect(x: 0, y: 0, width: Int(width), height: Int(height))
}
private func wkInjectUserScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {}
private func wkEvaluateScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {
    guard let wk = wk, let source = source else { return }
    coord(wk).webView.evaluateJavaScript(String(cString: source))
}

// The only place the opaque ViewHandle is interpreted as a UIView*.
private func embedViewOp(_ host: UnsafeMutableRawPointer?, _ view: UnsafeMutableRawPointer?) {
    guard let host = host, let view = view else { return }
    let c = coord(host)
    let seamView = Unmanaged<UIView>.fromOpaque(view).takeUnretainedValue()
    seamView.frame = c.container.bounds
    seamView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    c.container.addSubview(seamView)
}
private func embedSetUrlText(_ host: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?) {}
private func embedSetBackEnabled(_ host: UnsafeMutableRawPointer?, _ enabled: Bool) {}
private func embedSetForwardEnabled(_ host: UnsafeMutableRawPointer?, _ enabled: Bool) {}

final class EmbeddingProofTests: XCTestCase {
    // Held for the test's lifetime so the async WKWebView callbacks fire.
    private var coordinator: EmbeddingProofCoordinator?

    func testChromeSurfaceEmbedsRendererViewViaOpaqueViewHandle() {
        let expectation = expectation(description: "embedding proof passes")
        var passed = false
        var detail = ""

        // Drive setup on the main thread WITHOUT blocking it (XCTest runs the
        // test method on the main thread; a `.main.sync` would deadlock). The
        // WKWebView callbacks + the expectation drive completion.
        DispatchQueue.main.async {
            let c = EmbeddingProofCoordinator { ok, msg in
                passed = ok
                detail = msg
                expectation.fulfill()
            }
            self.coordinator = c
            // Host the CONTAINER in the test window so the WKWebView renders; the
            // renderer's view is embedded INTO the container by the seam's
            // embedView op (driven from Zig in start()), NOT here.
            let window = testWindow()
            c.container.frame = window.bounds
            c.container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(c.container)
            c.start()
        }

        wait(for: [expectation], timeout: 30)
        XCTAssertTrue(passed, "iOS embedding proof failed: \(detail)")
    }
}

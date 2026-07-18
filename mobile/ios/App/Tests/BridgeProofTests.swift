// BridgeProofTests — the iOS script-message BRIDGE seam proof, FOLDED into the
// real app's XCTest target (spec build-mobile-shell, stories 7/11; ADR-0009
// story-8 web3-hook parity). Replaces the standalone hand-assembled
// `BridgeProof.swift` + `bridge-proof.sh` spike with the SAME assertion,
// compiled + linked by the REAL Xcode project and run via `xcodebuild test` —
// the Android precedent (`BridgeSeamTest` is an instrumented test in the real
// app module).
//
// It round-trips ONE message BOTH ways through the pinned `Renderer` seam over a
// WKWebView via the already-exported proof C-ABI (`wezig_ios_bridge_proof_*`,
// retained in the real `libwezig_mobile.a`): inject `window.wezig.ping` +
// register the `wezig` channel THROUGH the seam, load a page that posts
// `ping-from-page` (page->native leg), native replies `pong-from-native`
// (native->page leg). This test case is the ONLY WKUserContentController /
// WKScriptMessageHandler toucher for the bridge proof.

import XCTest
import UIKit
import WebKit

private let bridgePageHTML = """
<!doctype html><html><head><meta name="viewport" \
content="width=device-width, initial-scale=1"></head>
<body><script>window.wezig.ping('ping-from-page')</script></body></html>
"""

final class BridgeProofCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    var proofCtx: UnsafeMutableRawPointer!
    private let onPass: () -> Void
    private var reported = false

    init(onPass: @escaping () -> Void) {
        self.onPass = onPass
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        webView = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        let wk = Unmanaged.passUnretained(self).toOpaque()
        let viewPtr = Unmanaged.passUnretained(webView).toOpaque()

        proofCtx = wezig_ios_bridge_proof_start(
            wk, viewPtr,
            wkInjectUserScript, wkEvaluateScript, wkSetScriptMessageHandler)

        let dataURL = "data:text/html;charset=utf-8,"
            + (bridgePageHTML.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        if let url = URL(string: dataURL) { webView.load(URLRequest(url: url)) }
    }

    // The page->native leg; `didReceive` fires on the MAIN queue (no marshalling).
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let name = message.name
        let body = "\(message.body)"
        name.withCString { np in body.withCString { bp in wezig_ios_on_script_message(proofCtx, np, bp) } }
        if wezig_ios_bridge_proof_passed(proofCtx) { report() }
    }

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        // Both legs should have landed shortly after load; if not, the timeout
        // fails the XCTest expectation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if wezig_ios_bridge_proof_passed(self.proofCtx) { self.report() }
        }
    }

    private func report() {
        if reported { return }
        reported = true
        onPass()
    }
}

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
    c.webView.configuration.userContentController.add(c, name: channel)
}
private func wkEvaluateScript(_ wk: UnsafeMutableRawPointer?, _ source: UnsafePointer<CChar>?) {
    guard let wk = wk, let source = source else { return }
    bridgeCoord(wk).webView.evaluateJavaScript(String(cString: source))
}

final class BridgeProofTests: XCTestCase {
    private var coordinator: BridgeProofCoordinator?

    func testScriptMessageBridgeRoundTripsBothWays() {
        let expectation = expectation(description: "bridge round-trips both ways")

        // Setup on the main thread without blocking it (a `.main.sync` from the
        // main-thread test method would deadlock).
        DispatchQueue.main.async {
            let c = BridgeProofCoordinator { expectation.fulfill() }
            self.coordinator = c
            let window = testWindow()
            c.webView.frame = window.bounds
            c.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(c.webView)
            c.start()
        }

        wait(for: [expectation], timeout: 30)
    }
}

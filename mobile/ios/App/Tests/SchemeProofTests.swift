// SchemeProofTests — the iOS custom-SCHEME seam proof, FOLDED into the real
// app's XCTest target (spec build-mobile-shell, stories 7/11; ADR-0009 story-9
// web3-hook parity). Replaces the standalone hand-assembled `SchemeProof.swift`
// + `scheme-proof.sh` spike with the SAME assertion, compiled + linked by the
// REAL Xcode project and run via `xcodebuild test` — the Android precedent
// (`SchemeSeamTest` is an instrumented test in the real app module).
//
// It serves ONE `wezig-test://hello` request from native THROUGH the pinned
// `Renderer` seam over a WKWebView via the already-exported proof C-ABI
// (`wezig_ios_scheme_proof_*`, retained in the real `libwezig_mobile.a`),
// demonstrating the iOS ORDERING CONSTRAINT: the WKURLSchemeHandler MUST be
// installed on the WKWebViewConfiguration BEFORE the WKWebView is created (the
// finding). This test case is the ONLY WKURLSchemeHandler toucher for the proof.

import XCTest
import UIKit
import WebKit

private let SCHEME_URI = "wezig-test://hello"

final class SchemeProofCoordinator: NSObject, WKNavigationDelegate {
    var webView: WKWebView!
    var proofCtx: UnsafeMutableRawPointer!
    var registeredScheme: String?
    fileprivate var pendingConfig: WKWebViewConfiguration?
    fileprivate var installedHandler: WezigSchemeHandler?

    private let done: (Bool) -> Void
    private var reported = false

    init(done: @escaping (Bool) -> Void) { self.done = done; super.init() }

    func start() {
        let wk = Unmanaged.passUnretained(self).toOpaque()

        // ORDERING CONSTRAINT: `registerScheme` runs BEFORE the WKWebView exists,
        // installing the handler on the config the webview copies.
        let config = WKWebViewConfiguration()
        self.pendingConfig = config
        let placeholderView = Unmanaged.passUnretained(self).toOpaque()
        proofCtx = wezig_ios_scheme_proof_start(wk, placeholderView, wkRegisterScheme)

        webView = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        webView.navigationDelegate = self
        if let url = URL(string: SCHEME_URI) { webView.load(URLRequest(url: url)) }
    }

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        if let t = wv.title { t.withCString { wezig_ios_scheme_on_title(proofCtx, $0) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let t = wv.title { t.withCString { wezig_ios_scheme_on_title(self.proofCtx, $0) } }
            self.report(wezig_ios_scheme_proof_passed(self.proofCtx))
        }
    }

    private func report(_ passed: Bool) {
        if reported { return }
        reported = true
        done(passed)
    }
}

final class WezigSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var coordinator: SchemeProofCoordinator?
    init(coordinator: SchemeProofCoordinator) { self.coordinator = coordinator }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let proofCtx = coordinator?.proofCtx else {
            urlSchemeTask.didFailWithError(NSError(domain: "wezig", code: 3)); return
        }
        guard let url = urlSchemeTask.request.url?.absoluteString else {
            urlSchemeTask.didFailWithError(NSError(domain: "wezig", code: 1)); return
        }
        var bodyPtr: UnsafePointer<UInt8>? = nil
        var bodyLen: Int = 0
        var ctPtr: UnsafePointer<CChar>? = nil
        let served = url.withCString { wezig_ios_serve_scheme(proofCtx, $0, &bodyPtr, &bodyLen, &ctPtr) }
        guard served, let bodyPtr = bodyPtr, let ctPtr = ctPtr else {
            urlSchemeTask.didFailWithError(NSError(domain: "wezig", code: 2)); return
        }
        let data = Data(bytes: bodyPtr, count: bodyLen)
        let contentType = String(cString: ctPtr)
        let response = HTTPURLResponse(
            url: urlSchemeTask.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private func schemeCoord(_ wk: UnsafeMutableRawPointer) -> SchemeProofCoordinator {
    return Unmanaged<SchemeProofCoordinator>.fromOpaque(wk).takeUnretainedValue()
}

private func wkRegisterScheme(_ wk: UnsafeMutableRawPointer?, _ scheme: UnsafePointer<CChar>?) {
    guard let wk = wk, let scheme = scheme else { return }
    let c = schemeCoord(wk)
    let name = String(cString: scheme)
    c.registeredScheme = name
    let handler = WezigSchemeHandler(coordinator: c)
    c.pendingConfig?.setURLSchemeHandler(handler, forURLScheme: name)
    c.installedHandler = handler
}

final class SchemeProofTests: XCTestCase {
    private var coordinator: SchemeProofCoordinator?

    func testCustomSchemeServesNativeBodyThatRenders() {
        let expectation = expectation(description: "scheme served + rendered")
        var passed = false

        // Setup on the main thread without blocking it (a `.main.sync` from the
        // main-thread test method would deadlock).
        DispatchQueue.main.async {
            let c = SchemeProofCoordinator { ok in passed = ok; expectation.fulfill() }
            self.coordinator = c
            let window = testWindow()
            c.start()
            c.webView.frame = window.bounds
            c.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(c.webView)
        }

        wait(for: [expectation], timeout: 30)
        XCTAssertTrue(passed, "iOS custom-scheme proof: served or rendered check failed")
    }
}

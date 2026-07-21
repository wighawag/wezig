// ShellVerify — the REAL-app self-check the mobile-verify iOS leg drives (spec
// build-mobile-shell, stories 4/7). Active ONLY under the `--wezig-verify` launch
// argument, so a normal launch is an ordinary browser. It asserts, against the
// SAME live shell the user drives (no separate harness):
//
//   1. navigate ONE page THROUGH the seams (a user-typed URL via the chrome),
//   2. a `.finished` lifecycle event reaches the chrome (the chrome reflected the
//      page's URL into the URL field — the seam delivered the event),
//   3. the embedded WKWebView renders NON-BLANK (WKWebView.takeSnapshot scan) —
//      the three facts the desktop `shell-test` / iOS `renderer-proof` assert, now
//      on the maintained app;
//   4. NEW (story 4): a background→foreground round-trip PRESERVES the page (the
//      URL after resume equals before, and the native WKWebView still holds it).
//
// It prints one PASS/FAIL line the CI leg greps. Snapshotting uses the backend's
// WKWebView (the sole WKWebView toucher exposes it) — a rendered page has >1
// distinct pixel, a blank/failed render is uniform (the desktop scanNonBlank bar).
//
// The verify page is a LOCAL, OFFLINE `data:` document (like the start page in
// WKWebViewShellController) — NOT a live network URL. Using `https://example.com/`
// made this leg a network-timing flake: on a cold CI simulator the remote fetch
// could miss the in-app settle window, so `.finished`/non-blank were both false
// even though the seams worked. A `data:` page loads synchronously offline, fires
// the full navigation lifecycle THROUGH the seam, and renders visibly non-blank —
// exercising the exact same three facts deterministically, with no network.
//
// Simulator only.

import UIKit
import WebKit

// A unique token painted into the page AND its title, so the URL-reflection match
// (host-less `data:` URL) keys off a stable marker rather than the whole blob.
private let verifyMarker = "WEZIG-VERIFY-OK"

// The offline verify page: dark-on-light body with a bold marker (guarantees the
// non-blank pixel scan) whose text also carries `verifyMarker` for the reflection
// match. Percent-encoded into a `data:` URL — no network, deterministic lifecycle.
private let verifyPageHTML = """
<!doctype html><html><head><meta name="viewport" \
content="width=device-width, initial-scale=1"><title>\(verifyMarker)</title></head>
<body style="margin:0;background:#101828;color:#f4f6fb;font:28px -apple-system;padding:2rem">
<h1>\(verifyMarker)</h1><p>wezig shell verify page (offline).</p>
</body></html>
"""

private let verifyURL = "data:text/html;charset=utf-8,"
    + (verifyPageHTML.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")

final class ShellVerify {
    private weak var controller: WKWebViewShellController?
    private weak var backend: WKWebViewBackend?

    private var navigatedURL: String?
    private var finishedReflected = false
    private var urlBeforeBackground: String?

    init(controller: WKWebViewShellController, backend: WKWebViewBackend) {
        self.controller = controller
        self.backend = backend
    }

    // Drive a navigation THROUGH the chrome/seams (exactly as a URL-field submit),
    // then let the lifecycle events + snapshot + lifecycle round-trip play out.
    func start() {
        guard let ctx = controller?.shellContext else {
            NSLog("FAIL: wezig shell verify — no shell context")
            return
        }
        navigatedURL = verifyURL
        // Navigate THROUGH the seam (a .navigate intent), not a raw WKWebView call.
        verifyURL.withCString { wezig_ios_shell_navigate(ctx, $0) }
        // The `.finished` event + non-blank snapshot are checked after the load
        // settles. The offline `data:` page loads synchronously, so a short beat
        // is plenty (no network to wait on).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkLoadedThenLifecycle()
        }
    }

    // The chrome reflected a URL into the field — the seam delivered a load event.
    // The verify target is a host-less `data:` URL, so match the stable marker the
    // page carries (present in the reflected data: URL) rather than a URL host.
    func onUrlReflected(_ text: String) {
        if navigatedURL != nil, text.contains(verifyMarker) {
            finishedReflected = true
        }
    }

    private func checkLoadedThenLifecycle() {
        guard let backend = backend else { return }
        let cfg = WKSnapshotConfiguration()
        backend.webView.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self = self else { return }
            let nonBlank = image.map(Self.imageIsNonBlank) ?? false
            let navigated = self.navigatedURL != nil
            NSLog("wezig verify: navigated=\(navigated) finished=\(self.finishedReflected) nonBlank=\(nonBlank)")
            guard navigated, self.finishedReflected, nonBlank else {
                NSLog("FAIL: wezig shell verify — navigate/finished/non-blank not all satisfied")
                return
            }
            // Now the NEW story-4 assertion: a background→foreground round-trip
            // must preserve the page.
            self.checkBackgroundForeground()
        }
    }

    // Simulate a background→foreground round-trip and assert the page survived
    // (host-only restoration: the native WKWebView keeps its own state, ADR-0010).
    private func checkBackgroundForeground() {
        guard let backend = backend, let controller = controller else { return }
        urlBeforeBackground = controller.reflectedURLText
        let liveURLBefore = backend.webView.url?.absoluteString

        // Drive the controller's lifecycle hooks exactly as the OS would on a
        // background→foreground round-trip.
        controller.viewWillDisappear(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, let backend = self.backend, let controller = self.controller else { return }
            controller.viewWillAppear(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let after = controller.reflectedURLText
                let liveURLAfter = backend.webView.url?.absoluteString
                let preserved = (after == self.urlBeforeBackground) && (liveURLAfter != nil) && (liveURLAfter == liveURLBefore)
                NSLog("wezig verify: bg/fg before=\(self.urlBeforeBackground ?? "nil") after=\(after) live=\(liveURLAfter ?? "nil")")
                if preserved {
                    NSLog("PASS: iOS shell browsed one page through the seams and preserved it across background/foreground")
                } else {
                    NSLog("FAIL: wezig shell verify — page not preserved across background/foreground")
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

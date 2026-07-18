// ProofTestSupport — shared helpers for the folded iOS seam-proof XCTest cases
// (embedding / bridge / scheme). These live in the real app's XCTest target
// (spec build-mobile-shell, stories 7/11) so each seam proof runs against the
// REAL Xcode project's build of the Zig core, the Android-precedent shape.

import UIKit

// A key window the WKWebView-hosting proofs attach their views to so the webview
// actually renders (an off-window WKWebView never composites, so takeSnapshot is
// blank). Reused across the three proof test cases; kept alive for the process.
private var gProofTestWindow: UIWindow?

func testWindow() -> UIWindow {
    if let w = gProofTestWindow { return w }
    let w = UIWindow(frame: UIScreen.main.bounds)
    w.rootViewController = UIViewController()
    w.makeKeyAndVisible()
    gProofTestWindow = w
    return w
}

// The non-blank scan the desktop `scanNonBlank` / the spike proofs use: a
// rendered page has >1 distinct pixel, a blank/failed render is uniform.
func imageIsNonBlank(_ image: UIImage) -> Bool {
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

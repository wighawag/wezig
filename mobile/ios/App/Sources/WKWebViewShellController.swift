// WKWebViewShellController — the root UIViewController that hosts the wezig iOS
// shell (spec build-mobile-shell, stories 1/3/4/5/6). It lays out a URL field + a
// back/forward toolbar + a content container, constructs the shared mobile chrome
// over the WKWebView `Renderer` + the mobile `ChromeSurface` (via `WKWebViewBackend`),
// and drives navigation ENTIRELY through the shell C-ABI (the chrome/seams) —
// never a raw WKWebView call (that discipline lives in WKWebViewBackend, the sole
// WKWebView toucher).
//
// ## What is wired here (all THROUGH the seams)
//
//   - URL field submit  -> `wezig_ios_shell_navigate`  (a .navigate intent)
//   - Back / Forward tap -> `wezig_ios_shell_go_back` / `_go_forward`
//   - Reload tap        -> `wezig_ios_shell_reload`
//   - The chrome reflects `Renderer` lifecycle events back into the URL field
//     text + the Back/Forward buttons' enabled state via the EmbedPlatform ops
//     (`reflectUrlText` / `reflectBackEnabled` / `reflectForwardEnabled`), so the
//     chrome MIRRORS the renderer's lifecycle exactly as the desktop chrome does
//     (story 5).
//
// ## Background/foreground state restoration is HOST-ONLY (ADR-0010, Resolved 1)
//
// A background→foreground round-trip preserves the current page WITHOUT any
// `Renderer` seam change: the native WKWebView persists and re-materialises its
// own page/scroll/history across the lifecycle transition (the OS mandate). This
// controller relies on that native save-restore; it adds NO suspend/resume/state
// seam method. `viewWillDisappear`/`viewWillAppear` observe the transition for
// logging + a defensive re-navigate ONLY if the native state was lost — but the
// common path is: the OS keeps the WKWebView alive, the page is still there.
//
// Simulator only: no signing, no Apple Developer account.

import UIKit
import WebKit

// The page the shell opens with. A `data:` document (offline, deterministic) so
// the app browses one real page on first launch with no network — the mobile
// equivalent of the desktop shell's smoke page. The user can type any URL after.
private let startPageHTML = """
<!doctype html><html><head><meta name="viewport" \
content="width=device-width, initial-scale=1"></head>
<body style="margin:0;background:#f4f6fb;color:#101828;font:20px -apple-system;padding:2rem">
<h1>wezig</h1><p>A minimal mobile browser. Type a URL above to navigate.</p>
</body></html>
"""

final class WKWebViewShellController: UIViewController, UITextFieldDelegate {
    private let backend = WKWebViewBackend()

    // Chrome widgets (the UIKit side of the mobile ChromeSurface).
    private let urlField = UITextField()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let contentContainer = UIView()

    // The last URL the chrome reflected (restored into the field; also used to
    // re-navigate defensively if the native webview state is ever lost).
    private var currentURLText: String = ""

    // The verify harness (only active under the `--wezig-verify` launch arg): the
    // REAL app self-checks the mobile-verify assertions (navigate + a `.finished`
    // lifecycle event reaching the chrome + a non-blank snapshot) AND the NEW
    // story-4 lifecycle assertion (background→foreground preserves the page). It
    // drives the SAME seams the user does — no separate harness (spec story 7).
    private var verify: ShellVerify?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        NSLog("wezig: linked Zig core abi=\(wezig_abi_version())")

        layoutChrome()
        startShell()

        if CommandLine.arguments.contains("--wezig-verify") {
            verify = ShellVerify(controller: self, backend: backend)
            verify?.start()
        }
    }

    // --- layout: URL field + back/forward toolbar + content container ----------
    private func layoutChrome() {
        // URL field.
        urlField.borderStyle = .roundedRect
        urlField.placeholder = "Enter a URL"
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.clearButtonMode = .whileEditing
        urlField.returnKeyType = .go
        urlField.delegate = self
        urlField.translatesAutoresizingMaskIntoConstraints = false

        // Toolbar buttons.
        backButton.setTitle("◀︎", for: .normal)
        forwardButton.setTitle("▶︎", for: .normal)
        reloadButton.setTitle("⟳", for: .normal)
        backButton.addTarget(self, action: #selector(onBack), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(onForward), for: .touchUpInside)
        reloadButton.addTarget(self, action: #selector(onReload), for: .touchUpInside)
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        let toolbar = UIStackView(arrangedSubviews: [backButton, forwardButton, urlField, reloadButton])
        toolbar.axis = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .center
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.backgroundColor = .black

        view.addSubview(toolbar)
        view.addSubview(contentContainer)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -8),

            contentContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // --- construct the shared mobile chrome over the two seams -----------------
    private func startShell() {
        let wk = Unmanaged.passUnretained(backend).toOpaque()
        let viewPtr = Unmanaged.passUnretained(backend.webView).toOpaque()
        let host = Unmanaged.passUnretained(self).toOpaque()

        let dataURL = "data:text/html;charset=utf-8,"
            + (startPageHTML.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")

        // `wezig_ios_shell_start` constructs the IosWebviewRenderer + MobileChromeSurface
        // + shared MobileChrome, registers the trivial marker scheme THROUGH the
        // seam at config-build time (the WKURLSchemeHandler is already installed on
        // the config in WKWebViewBackend.init, before the webview was created — the
        // ordering constraint), embeds the renderer's opaque view through the
        // surface, and navigates the start page. All THROUGH the seams.
        backend.shellCtx = wezig_ios_shell_start(
            wk, viewPtr,
            wkNavigate, wkReload, wkStop, wkGoBack, wkGoForward,
            wkCanGoBack, wkCanGoForward, wkSetViewportSize,
            wkInjectUserScript, wkEvaluateScript,
            wkSetScriptMessageHandler, wkRegisterScheme,
            host, embedViewOp, embedSetUrlText, embedSetBackEnabled, embedSetForwardEnabled,
            wezigMarkerScheme, dataURL)
    }

    // --- chrome widget reflection (called from the EmbedPlatform ops) ----------
    // The chrome drives these on `Renderer` lifecycle events; the field/buttons
    // MIRROR the renderer's state (story 5), never the other way round.

    func embedContentView(_ seamView: UIView) {
        seamView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(seamView)
        NSLayoutConstraint.activate([
            seamView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            seamView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            seamView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            seamView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }
    func reflectUrlText(_ text: String) {
        currentURLText = text
        // Don't clobber the field while the user is editing it.
        if !urlField.isEditing { urlField.text = text }
        verify?.onUrlReflected(text)
    }

    // The URL the chrome last reflected (the verify harness reads it to assert the
    // page survived a background→foreground round-trip).
    var reflectedURLText: String { currentURLText }
    var contentContainerView: UIView { contentContainer }
    var shellContext: UnsafeMutableRawPointer? { backend.shellCtx }
    func reflectBackEnabled(_ enabled: Bool) { backButton.isEnabled = enabled }
    func reflectForwardEnabled(_ enabled: Bool) { forwardButton.isEnabled = enabled }

    // --- user intents -> shell C-ABI (THROUGH the chrome/seams) ----------------

    @objc private func onBack() {
        guard let ctx = backend.shellCtx else { return }
        wezig_ios_shell_go_back(ctx)
    }
    @objc private func onForward() {
        guard let ctx = backend.shellCtx else { return }
        wezig_ios_shell_go_forward(ctx)
    }
    @objc private func onReload() {
        guard let ctx = backend.shellCtx else { return }
        wezig_ios_shell_reload(ctx)
    }

    // URL field submit: normalise a bare host into an https URL, then navigate
    // THROUGH the chrome (`wezig_ios_shell_navigate` fires a .navigate intent).
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        guard let ctx = backend.shellCtx, let raw = textField.text, !raw.isEmpty else { return true }
        let normalized = Self.normalizeURL(raw)
        normalized.withCString { wezig_ios_shell_navigate(ctx, $0) }
        return true
    }

    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        return "https://" + trimmed
    }

    // --- app lifecycle: state restoration is HOST-ONLY (ADR-0010) --------------
    // The native WKWebView save-restores its own page/scroll/history across
    // background/foreground (the OS mandate); we add NO seam method. We only log
    // the transition and, defensively, re-navigate the last URL if the webview's
    // native state was somehow lost (e.g. a memory-pressure teardown) — driving
    // the EXISTING navigate op, not a new seam method.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NSLog("wezig: backgrounding — WKWebView state persists natively (host-only, no seam change)")
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Native state normally survives; restore the URL field to mirror it.
        if !currentURLText.isEmpty { urlField.text = currentURLText }
        if backend.webView.url == nil, let ctx = backend.shellCtx, !currentURLText.isEmpty {
            // Defensive: the native page state was lost — re-drive the EXISTING
            // navigate op (host-only restoration, no new seam method).
            NSLog("wezig: foreground restore — native state lost, re-navigating last URL via the seam")
            currentURLText.withCString { wezig_ios_shell_navigate(ctx, $0) }
        }
    }
}

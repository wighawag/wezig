---
source: android.webkit.WebViewClient / WebView docs + the android-renderer-backend-oneshot spike (mobile/android)
---

# Android WebViewClient load callbacks run on non-UI (binder) threads — marshal to the seam thread

Verified while implementing the Android `Renderer` backend (task
`android-renderer-backend-oneshot`, spec `explore-mobile-shell` Q5/story 5).

**Ground truth.** `android.webkit.WebViewClient` load callbacks
(`onPageStarted`/`onPageCommitVisible`/`onPageFinished`/`onReceivedError`) and
`WebViewClient.shouldInterceptRequest` can be invoked on a NON-UI (binder)
thread, not the thread that owns the `WebView`. The `Renderer` seam's
`LifecycleCallback` (and the desktop reference, which emits on the GTK main
loop) is a single-sink contract expected to be delivered serialized on ONE
thread.

**Resolution taken.** `WezigWebViewController` re-posts every
`WebViewClient`/`WebChromeClient` callback onto the UI thread via
`Handler(Looper.getMainLooper())` BEFORE it crosses the JNI boundary into the
Zig seam callback (`android_renderer.zig`). The native side does no cross-thread
work, so the chrome sees lifecycle events exactly as on desktop.

**Why it matters downstream.** This is Android-specific: iOS's
`WKNavigationDelegate` already fires on the main queue, so the iOS backend has no
equivalent gap. The same marshalling is load-bearing for
`mobile-web3-hooks-parity`: `shouldInterceptRequest` (the `ipfs://` custom-scheme
hook) ALSO runs on a binder thread and must marshal its native-served response
back correctly — the thread contract established here is the pattern that task
inherits. Recorded durably in `mobile/android/README.md` (backend findings) and
the `android_renderer.zig` module doc.

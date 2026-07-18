---
title: iOS shell — real Xcode/SwiftPM project browsing one page through the seams
slug: ios-shell-xcode-project
spec: build-mobile-shell
blockedBy: [mobile-chrome-loop-zig]
covers: [1, 3, 4, 5, 6]
---

## What to build

Replace the iOS spike's hand-assembled `swiftc` scripts with a REAL, maintainable Xcode/SwiftPM project: a minimal app whose root `UIViewController` hosts the mobile `Renderer` (`WKWebView`) + `ChromeSurface` driven by the shared mobile chrome (`mobile-chrome-loop-zig`), with a URL field + back/forward toolbar, and background→foreground page-state restoration.

End-to-end: the project builds the Zig static lib as a normal build phase (not a bespoke script), the `UIViewController` builds the `WKWebView`-backed `Renderer` + the `MobileChromeSurface`, constructs the shared mobile chrome over them, lays out a URL field + back/forward + the embedded `WKWebView`, and wires:
- **URL entry → navigate**, **back/forward → goBack/goForward**, THROUGH the chrome/seams;
- **lifecycle events → widgets** via the chrome;
- **scheme-set-at-config-time (iOS finding):** any custom scheme handler is installed on the `WKWebViewConfiguration` BEFORE the `WKWebView` is created (the config-ordering constraint) — this shell registers only a trivial marker scheme, but the wiring must thread the scheme set into the config at build time;
- **app lifecycle → state restoration (HOST-ONLY, Resolved decision 1):** background/foreground preserves the current page via the `UIViewController` host + native `WKWebView` state, with no `Renderer` seam change.

Stay Simulator-only + unsigned (signing/provisioning is Slice C).

## Acceptance criteria

- [ ] A real Xcode/SwiftPM project (not the `build-and-run.sh` `swiftc` script) builds the app and compiles the Zig static lib as a normal build phase/step.
- [ ] The root `UIViewController` hosts the `WKWebView` `Renderer` + `ChromeSurface` via the shared mobile chrome; a URL field + back/forward toolbar drive navigation THROUGH the chrome/seams (no raw `WKWebView` calls outside the backend).
- [ ] The URL field reflects the current page and back/forward enable/disable correctly from `Renderer` lifecycle events (via the chrome).
- [ ] The custom scheme handler (trivial marker) is installed on the `WKWebViewConfiguration` BEFORE the `WKWebView` is created (config-ordering finding honoured); the wiring threads the scheme set into the config at build time.
- [ ] A background→foreground round-trip preserves the current page (host-only via the `UIViewController` + native `WKWebView` state); no `Renderer` seam method was added.
- [ ] The app builds + launches on an iOS 17 Simulator (unsigned, no Apple Developer account); it stays Simulator-only.
- [ ] The desktop v0 gate is untouched and green; the iOS backend remains the sole `WKWebView` toucher.

## Blocked by

- `mobile-chrome-loop-zig` — hosts the shared chrome the `UIViewController` constructs. (File-orthogonal to the Android shell — `mobile/ios/**` vs `mobile/android/**` — so it may run in parallel with `android-shell-app`.)

## Prompt

> Goal: replace the iOS spike's hand-assembled `swiftc` scripts with a REAL Xcode/SwiftPM project (spec `build-mobile-shell`, stories 1/3/4/5/6): a minimal app whose `UIViewController` hosts the `WKWebView` `Renderer` + `ChromeSurface` driven by the shared mobile chrome, with a URL field + back/forward toolbar and background→foreground page-state restoration (HOST-ONLY per Resolved decision 1 — no `Renderer` seam change). The project must build the Zig static lib as a NORMAL build phase, not a bespoke script. Honour the iOS scheme-ordering finding: install any custom scheme handler on the `WKWebViewConfiguration` BEFORE creating the `WKWebView` (this shell uses only a trivial marker scheme, but the wiring must thread the scheme set in at config-build time).
>
> Read: `mobile/ios/**` (the spike sources — `main.swift`, the proof Swift files, `build-and-run.sh`, `Info.plist`, `wezig_mobile.h` — to turn into a real project), `src/ios_webview_renderer.zig` (the `WKWebView` `Renderer` backend + its documented scheme-ordering constraint), `src/mobile_chrome_surface.zig` (`MobileChromeSurface`), the shared mobile chrome from `mobile-chrome-loop-zig`, `docs/mobile-exploration-findings.md` + ADR-0008/0009, and `work/notes/findings/ios-wkurlschemehandler-registration-ordering-2026-07-18.md`. Keep the iOS backend the SOLE `WKWebView` toucher; drive navigation only through the chrome/seams. Stay Simulator-only + unsigned (signing is Slice C). "Done" = a real Xcode/SwiftPM project browses one page through the seams with a URL-bar/back-forward chrome, survives a background/foreground round-trip, builds the Zig lib as a normal build phase, and launches on an iOS 17 Simulator; desktop gate untouched.

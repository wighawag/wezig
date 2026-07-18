//! The C-ABI surface the mobile shells (iOS/Android) link against.
//!
//! On mobile, Zig builds a STATIC LIBRARY that the OS-native shell hosts:
//!   - iOS: a Swift/Xcode app links `libwezig_mobile.a` and calls these
//!     `export fn`s through a C-ABI header, then drives a `WKWebView`.
//!   - Android: a Gradle/NDK app loads the static lib through a JNI shim and
//!     drives an `android.webkit.WebView`.
//!
//! This module is the NARROW, stable C boundary those shims call: it proves the
//! Zig core is linked and live from the native side, without dragging the shell
//! seams (which link WebKitGTK/GTK on desktop) into the mobile build. The
//! functions here are deliberately minimal — an ABI-version integer and a
//! greeting string — exactly enough for the toolchain tasks to prove Zig↔native
//! linkage end-to-end. Richer surface (the `ChromeSurface` half of the split
//! `Toolkit`, ADR-0008) is wired by the downstream mobile renderer/embedding
//! tasks; keeping this file minimal keeps the toolchain proof honest.
//!
//! These are C-callable (`export fn`, C ABI), so they are usable from Swift
//! (via a bridging header) and from C/JNI alike. The library module already
//! links libc (stb_truetype), so returning a static C string is safe.

const std = @import("std");
const branding = @import("branding.zig");

/// The mobile C-ABI contract version. Bumped when the exported surface below
/// changes shape, so a native shim can assert it links the ABI it expects.
pub const abi_version: c_int = 1;

/// Return the mobile C-ABI version. The native shim calls this first to prove
/// the Zig static lib is linked and callable.
export fn wezig_abi_version() c_int {
    return abi_version;
}

/// A NUL-terminated greeting the native shim can display (e.g. in a WebView or a
/// log line) to prove the Zig core is live. Points at static storage owned by
/// the library; the caller must NOT free it.
export fn wezig_greeting() [*:0]const u8 {
    return "wezig mobile core linked";
}

test "abi_version is the pinned contract version" {
    try std.testing.expectEqual(@as(c_int, 1), wezig_abi_version());
}

test "greeting is a stable non-empty C string" {
    const g = std.mem.span(wezig_greeting());
    try std.testing.expect(g.len > 0);
    try std.testing.expectEqualStrings("wezig mobile core linked", g);
}

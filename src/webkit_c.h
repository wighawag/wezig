/* Zig `@cImport` bridge for GTK4 + WebKitGTK 6.0 (ADR-0005 `Renderer` seam).
 *
 * `@cImport(@cInclude("webkit/webkit.h"))` does not work verbatim on Zig
 * 0.16's translate-c: the GObject/GTK headers use two constructs its C
 * frontend cannot lower. This header includes the SAME real system headers the
 * task specifies, and only NEUTRALISES those two constructs first, so the rest
 * of the GTK4/WebKit API translates unchanged. It links nothing; it is purely
 * the translation shim. `shell.zig` is the sole importer.
 *
 * 1. `G_GNUC_BEGIN/END_IGNORE_DEPRECATIONS` expand to `_Pragma("GCC diagnostic
 *    ...")`. `G_DECLARE_FINAL_TYPE` (used pervasively by GTK/WebKit) places
 *    them in declaration position, where translate-c chokes ("unknown type
 *    name 'diagnostic'"). We grab GLib's macro header directly (opening its
 *    "only <glib.h>" guard with GLIB_COMPILATION) and redefine both to empty
 *    BEFORE any real header expands them. The pragmas only silence deprecation
 *    warnings, so dropping them costs nothing here.
 *
 * 2. `glib_typeof` turns `g_object_ref(x)` into a result-CASTING macro
 *    (`((glib_typeof(x))(g_object_ref)(x))`). The discarded cast inside the
 *    `g_set_object()` / `g_set_weak_pointer()` static-inline helpers is what
 *    translate-c mis-lowers to a result-typeless `@ptrCast`. Undefining
 *    `glib_typeof` after <glib.h> is set up leaves `g_object_ref` a plain
 *    function call, so both helpers translate cleanly. GLib's version macros
 *    stay untouched, so no API is hidden.
 *
 * The importer must also `@cDefine("__GI_SCANNER__", "1")` (skips the
 * g_autoptr cleanup helpers, which translate-c likewise cannot parse) and
 * `@cDefine("GTK_COMPILATION", "1")` (satisfies gdkversionmacros.h's
 * direct-include guard, which `#pragma once` can otherwise trip depending on
 * the header visitation order under WebKit's include graph).
 */

#define GLIB_COMPILATION
#include <glib/gmacros.h>
#undef GLIB_COMPILATION
#undef G_GNUC_BEGIN_IGNORE_DEPRECATIONS
#undef G_GNUC_END_IGNORE_DEPRECATIONS
#define G_GNUC_BEGIN_IGNORE_DEPRECATIONS
#define G_GNUC_END_IGNORE_DEPRECATIONS

#include <glib.h>
#undef glib_typeof

#include <gtk/gtk.h>
#include <webkit/webkit.h>

//! `GtkToolkit`: the chrome/toolkit seam (toolkit.zig) implemented on GTK4
//! (ADR-0006). This is the ONE place GTK is touched for chrome: it owns the
//! shell WINDOW (windowing behind the seam, story 6), builds the toolbar (URL
//! entry + Back/Forward/Reload buttons), embeds the renderer's opaque view, and
//! runs the GTK main loop, translating GTK widget signals into the seam's
//! `ChromeIntent`s. A Qt or Zig-native toolkit implements the SAME toolkit.zig
//! interface later and is swapped in behind it.
//!
//! Like `sdl.zig` and `system_webview_renderer.zig`, this file links a native
//! library and lives in the SHELL executable ONLY, never the `wezig` library
//! module (see `build.zig`).
//!
//! The GTK4 binding comes through `webkit_c.h` (which also pulls in <gtk/gtk.h>);
//! see that header for why a thin translate-c shim is needed.

const std = @import("std");
const wezig = @import("wezig");
const seam = wezig.toolkit;
const renderer_seam = wezig.renderer;

const c = @cImport({
    @cDefine("__GI_SCANNER__", "1");
    @cDefine("GTK_COMPILATION", "1");
    @cInclude("webkit_c.h");
});

/// Errors the toolkit can report to its caller (the shell executable's `main`).
pub const ToolkitError = error{
    /// GTK could not initialise (no display / no `$DISPLAY`, and no Xvfb).
    GtkInit,
};

/// A `Toolkit` backed by GTK4. Construct with `init` (initialises GTK), obtain
/// the seam value with `toolkit()`, and hand THAT to the chrome. The chrome
/// never sees a GTK type.
pub const GtkToolkit = struct {
    window: ?*c.GtkWindow = null,
    /// Vertical box: [toolbar][content]. The window's single child.
    root_box: ?*c.GtkWidget = null,
    url_entry: ?*c.GtkWidget = null,
    back_btn: ?*c.GtkWidget = null,
    forward_btn: ?*c.GtkWidget = null,
    reload_btn: ?*c.GtkWidget = null,
    loop: ?*c.GMainLoop = null,
    cb: ?seam.ChromeCallback = null,

    /// Initialise GTK4. Returns `error.GtkInit` (rather than aborting like
    /// `gtk_init`) when there is no usable display, so the caller can report a
    /// clean error headlessly with no Xvfb.
    pub fn init() ToolkitError!GtkToolkit {
        if (c.gtk_init_check() == 0) return error.GtkInit;
        return .{};
    }

    pub fn toolkit(self: *GtkToolkit) seam.Toolkit {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = seam.Toolkit.VTable{
        .createWindow = createWindow,
        .setTitle = setTitle,
        .embedView = embedView,
        .present = present,
        .run = run,
        .quit = quit,
        .setUrlText = setUrlText,
        .setBackEnabled = setBackEnabled,
        .setForwardEnabled = setForwardEnabled,
        .setChromeCallback = setChromeCallback,
    };

    fn createWindow(ctx: *anyopaque, width: c_int, height: c_int) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));

        const window: *c.GtkWindow = @ptrCast(c.gtk_window_new());
        c.gtk_window_set_default_size(window, width, height);
        self.window = window;

        // Root vertical box: toolbar on top, content fills the rest.
        const root_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_window_set_child(window, root_box);
        self.root_box = root_box;

        // Toolbar: [Back][Forward][Reload][ URL entry (expands) ].
        const toolbar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_box_append(@ptrCast(root_box), toolbar);

        const back_btn = c.gtk_button_new_with_label("◀");
        const forward_btn = c.gtk_button_new_with_label("▶");
        const reload_btn = c.gtk_button_new_with_label("⟳");
        const url_entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(url_entry, 1);
        c.gtk_widget_set_sensitive(back_btn, 0);
        c.gtk_widget_set_sensitive(forward_btn, 0);
        c.gtk_box_append(@ptrCast(toolbar), back_btn);
        c.gtk_box_append(@ptrCast(toolbar), forward_btn);
        c.gtk_box_append(@ptrCast(toolbar), reload_btn);
        c.gtk_box_append(@ptrCast(toolbar), url_entry);
        self.back_btn = back_btn;
        self.forward_btn = forward_btn;
        self.reload_btn = reload_btn;
        self.url_entry = url_entry;

        // Wire widget signals -> chrome intents.
        signalConnect(@ptrCast(back_btn), "clicked", @ptrCast(&onBackClicked), self);
        signalConnect(@ptrCast(forward_btn), "clicked", @ptrCast(&onForwardClicked), self);
        signalConnect(@ptrCast(reload_btn), "clicked", @ptrCast(&onReloadClicked), self);
        signalConnect(@ptrCast(url_entry), "activate", @ptrCast(&onUrlActivate), self);
        signalConnect(@ptrCast(window), "destroy", @ptrCast(&onDestroy), self);
    }

    fn setTitle(ctx: *anyopaque, title: [*:0]const u8) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));
        if (self.window) |w| c.gtk_window_set_title(w, title);
    }

    fn embedView(ctx: *anyopaque, view: renderer_seam.ViewHandle) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));
        // The opaque handle IS a GtkWidget (the WebView). Append it below the
        // toolbar so it fills the remaining space. The toolkit interprets the
        // handle; the chrome only passed it through from `Renderer.view()`.
        const widget: *c.GtkWidget = @ptrCast(@alignCast(view));
        c.gtk_widget_set_hexpand(widget, 1);
        c.gtk_widget_set_vexpand(widget, 1);
        if (self.root_box) |box| c.gtk_box_append(@ptrCast(box), widget);
    }

    fn present(ctx: *anyopaque) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));
        if (self.window) |w| c.gtk_window_present(w);
    }

    fn run(ctx: *anyopaque) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));
        const loop = c.g_main_loop_new(null, 0);
        self.loop = loop;
        c.g_main_loop_run(loop);
        c.g_main_loop_unref(loop);
        self.loop = null;
    }

    fn quit(ctx: *anyopaque) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));
        if (self.loop) |l| c.g_main_loop_quit(l);
    }

    fn setUrlText(ctx: *anyopaque, text: [*:0]const u8) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));
        if (self.url_entry) |e| c.gtk_editable_set_text(@ptrCast(e), text);
    }

    fn setBackEnabled(ctx: *anyopaque, enabled: bool) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));
        if (self.back_btn) |b| c.gtk_widget_set_sensitive(b, @intFromBool(enabled));
    }

    fn setForwardEnabled(ctx: *anyopaque, enabled: bool) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));
        if (self.forward_btn) |b| c.gtk_widget_set_sensitive(b, @intFromBool(enabled));
    }

    fn setChromeCallback(ctx: *anyopaque, cb: seam.ChromeCallback) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(ctx));
        self.cb = cb;
    }

    fn emit(self: *GtkToolkit, intent: seam.ChromeIntent) void {
        if (self.cb) |cb| cb.onIntent(cb.ctx, intent);
    }

    // --- GTK signals -> chrome intents ---

    fn onBackClicked(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(data));
        self.emit(.back);
    }
    fn onForwardClicked(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(data));
        self.emit(.forward);
    }
    fn onReloadClicked(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(data));
        self.emit(.reload);
    }
    fn onUrlActivate(entry: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(data));
        const text = c.gtk_editable_get_text(@ptrCast(entry));
        self.emit(.{ .navigate = std.mem.span(text) });
    }
    fn onDestroy(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self: *GtkToolkit = @ptrCast(@alignCast(data));
        self.emit(.closed);
    }
};

/// `g_signal_connect` is a macro over `g_signal_connect_data`; replicate it.
fn signalConnect(instance: c.gpointer, detailed_signal: [*:0]const u8, handler: c.GCallback, data: c.gpointer) void {
    _ = c.g_signal_connect_data(instance, detailed_signal, handler, data, null, 0);
}

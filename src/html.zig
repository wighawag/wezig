//! The v0 HTML parser: turns a FIXED, documented subset of HTML into a DOM
//! tree. This is NOT a WHATWG-conformant parser; the subset is an explicit
//! element/attribute ALLOWLIST (below) and anything outside it is reported as a
//! `Diagnostics` entry rather than handled.
//!
//! The parser is split at a `Tokenizer | TreeBuilder` seam with a token stream
//! as the currency (see `docs/adr/0001-...`): a real WHATWG tokenizer can later
//! drop in against the same `Token` type while the tree builder grows toward
//! the insertion-mode state machine independently. Consumers should test at the
//! DOM seam (fixture HTML in, assert DOM structure + diagnostic codes), NOT on
//! internal tokenizer state.
//!
//! Decisions (see the task done record for the why):
//!   - The allowlist POLICY lives in the `TreeBuilder` (`element_allowlist` /
//!     `attr_allowlist`), NOT the tokenizer. The tokenizer stays dumb with ONE
//!     documented exception: it treats `<style>` content as RAW TEXT (so `{}`,
//!     `:` etc. inside a stylesheet are not tokenized as HTML), mirroring
//!     WHATWG's own raw-text handling.
//!   - v0 captures BOTH `<style>` block text (as a text child of the `<style>`
//!     element) and the `style=""` attribute value (as a normal attribute) onto
//!     the DOM. Parsing/cascading that CSS is a SEPARATE later task.
//!   - DOM `Node`s carry a `parent` pointer (a later descendant-combinator
//!     matcher walks ancestors). Nodes are arena-owned by the `Document`.
//!   - Non-allowlisted elements emit `non_allowlisted_element` (severity
//!     `warning`) and are SKIPPED without aborting: their subtree's allowlisted
//!     descendants are still parsed and attached to the skipped element's
//!     parent (the element itself just never appears in the tree).
//!
//! ## v0 element + attribute allowlist (seed for `document-v0-subset-limits`)
//!
//! This is the authoritative v0 subset. It is deliberately small: enough
//! structure to exercise block/inline layout and the `<style>`/`style=""` CSS
//! path, nothing more. Later tasks EXTEND these sets; keep additions explicit.
//!
//! Allowlisted elements:
//!   html, head, body, style,
//!   div, p, span, a,
//!   h1, h2, h3, h4, h5, h6,
//!   ul, ol, li,
//!   strong, em, b, i, br
//!
//! Allowlisted attributes:
//!   - GLOBAL (any allowlisted element): id, class, style
//!   - `a` only: href
//!
//! Everything else (other elements, other attributes, comments as structure,
//! doctype, scripts) is out of the v0 subset. Non-allowlisted ELEMENTS are
//! reported via `non_allowlisted_element`; non-allowlisted ATTRIBUTES are
//! silently dropped in v0 (they are not element boundaries and have no v0
//! diagnostic code; a later task may add one).

const std = @import("std");
const diagnostics = @import("diagnostics.zig");

const Diagnostics = diagnostics.Diagnostics;
const Span = diagnostics.Span;

// ---------------------------------------------------------------------------
// Allowlist policy (lives with the tree builder, not the tokenizer).
// ---------------------------------------------------------------------------

/// The v0 allowlisted element tag names (lower-case, ASCII). Seed for the
/// `document-v0-subset-limits` doc.
pub const element_allowlist = [_][]const u8{
    "html", "head",   "body", "style",
    "div",  "p",      "span", "a",
    "h1",   "h2",     "h3",   "h4",
    "h5",   "h6",     "ul",   "ol",
    "li",   "strong", "em",   "b",
    "i",    "br",
};

/// Attributes allowed on ANY allowlisted element.
pub const global_attr_allowlist = [_][]const u8{ "id", "class", "style" };

fn isAllowlistedElement(name: []const u8) bool {
    for (element_allowlist) |e| {
        if (std.ascii.eqlIgnoreCase(name, e)) return true;
    }
    return false;
}

/// Whether `attr` is allowed on element `tag`. Global attributes are allowed on
/// every allowlisted element; `href` is allowed on `a` only.
fn isAllowlistedAttr(tag: []const u8, attr: []const u8) bool {
    for (global_attr_allowlist) |a| {
        if (std.ascii.eqlIgnoreCase(attr, a)) return true;
    }
    if (std.ascii.eqlIgnoreCase(tag, "a") and std.ascii.eqlIgnoreCase(attr, "href")) return true;
    return false;
}

/// Void elements have no end tag and no children in the v0 subset.
fn isVoidElement(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "br");
}

/// Elements whose content the tokenizer reads as RAW TEXT (the documented
/// exception). Only `<style>` in v0.
fn isRawTextElement(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "style");
}

// ---------------------------------------------------------------------------
// Token stream (the `Tokenizer | TreeBuilder` currency).
// ---------------------------------------------------------------------------

/// One HTML attribute, name + value borrowed from the source (the tokenizer
/// does not own or copy input text).
pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

/// A single token emitted by the `Tokenizer`. Kept deliberately close to the
/// WHATWG token shapes so a conformant tokenizer can emit the same currency.
pub const Token = union(enum) {
    start_tag: StartTag,
    end_tag: EndTag,
    text: Text,
    comment: Comment,

    pub const StartTag = struct {
        name: []const u8,
        attrs: []const Attr,
        self_closing: bool,
        span: Span,
    };
    pub const EndTag = struct {
        name: []const u8,
        span: Span,
    };
    pub const Text = struct {
        data: []const u8,
        span: Span,
    };
    pub const Comment = struct {
        data: []const u8,
        span: Span,
    };
};

/// The dumb subset tokenizer. It scans the input once and produces a `Token`
/// slice. Its ONE non-trivial behaviour is the raw-text exception for
/// `<style>`: after a `<style>` start tag it consumes everything up to the next
/// `</style>` as a single text token, so CSS punctuation is not misread as
/// HTML.
///
/// All string fields in the emitted tokens BORROW from `input`; the caller keeps
/// `input` alive for the tokens' lifetime. Attribute slices are arena-owned by
/// `arena`.
pub const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator, input: []const u8) Tokenizer {
        return .{ .input = input, .arena = arena };
    }

    /// Tokenize the whole input into an arena-owned slice of tokens.
    pub fn tokenize(self: *Tokenizer) ![]const Token {
        var tokens: std.ArrayList(Token) = .empty;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '<') {
                if (try self.readMarkup()) |tok| {
                    try tokens.append(self.arena, tok);
                    // Raw-text exception: after a <style> start tag, swallow its
                    // content as one text token up to </style>.
                    if (tok == .start_tag and isRawTextElement(tok.start_tag.name) and !tok.start_tag.self_closing) {
                        if (self.readRawText(tok.start_tag.name)) |raw| {
                            try tokens.append(self.arena, raw);
                        }
                    }
                }
            } else {
                try tokens.append(self.arena, self.readText());
            }
        }
        return tokens.toOwnedSlice(self.arena);
    }

    /// Read a run of character data up to the next `<` (or end of input).
    fn readText(self: *Tokenizer) Token {
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '<') : (self.pos += 1) {}
        return .{ .text = .{ .data = self.input[start..self.pos], .span = .{ .start = start, .end = self.pos } } };
    }

    /// Read raw text up to (but not consuming) the matching `</name>`. Emits a
    /// text token for the content; the `</name>` end tag is left for the main
    /// loop to tokenize normally.
    fn readRawText(self: *Tokenizer, name: []const u8) ?Token {
        const start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '<' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '/') {
                const after = self.pos + 2;
                if (after + name.len <= self.input.len and
                    std.ascii.eqlIgnoreCase(self.input[after .. after + name.len], name))
                {
                    break;
                }
            }
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return .{ .text = .{ .data = self.input[start..self.pos], .span = .{ .start = start, .end = self.pos } } };
    }

    /// At a `<`: dispatch to comment, end tag, or start tag. Returns `null` for
    /// a stray `<` treated as text-less noise (rare; consumed as text instead).
    fn readMarkup(self: *Tokenizer) !?Token {
        const start = self.pos;
        // Comment: <!-- ... -->
        if (std.mem.startsWith(u8, self.input[self.pos..], "<!--")) {
            self.pos += 4;
            const data_start = self.pos;
            const end_rel = std.mem.indexOf(u8, self.input[self.pos..], "-->");
            const data_end = if (end_rel) |r| self.pos + r else self.input.len;
            self.pos = if (end_rel) |r| self.pos + r + 3 else self.input.len;
            return .{ .comment = .{ .data = self.input[data_start..data_end], .span = .{ .start = start, .end = self.pos } } };
        }
        // Doctype / other bogus `<!...>`: consume to `>` and drop (emit nothing).
        if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '!') {
            self.skipTo('>');
            return null;
        }
        // End tag: </name>
        if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '/') {
            self.pos += 2;
            const name = self.readTagName();
            self.skipTo('>');
            if (name.len == 0) return null;
            return .{ .end_tag = .{ .name = name, .span = .{ .start = start, .end = self.pos } } };
        }
        // Start tag: <name attrs...>
        if (self.pos + 1 < self.input.len and isNameStart(self.input[self.pos + 1])) {
            self.pos += 1;
            const name = self.readTagName();
            const attrs = try self.readAttrs();
            const self_closing = self.consumeTagEnd();
            return .{ .start_tag = .{
                .name = name,
                .attrs = attrs,
                .self_closing = self_closing,
                .span = .{ .start = start, .end = self.pos },
            } };
        }
        // Stray `<` not starting a tag: treat the `<` as one char of text.
        self.pos += 1;
        return .{ .text = .{ .data = self.input[start..self.pos], .span = .{ .start = start, .end = self.pos } } };
    }

    fn readTagName(self: *Tokenizer) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len and isNameChar(self.input[self.pos])) : (self.pos += 1) {}
        return self.input[start..self.pos];
    }

    fn readAttrs(self: *Tokenizer) ![]const Attr {
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;
            const c = self.input[self.pos];
            if (c == '>' or c == '/') break;
            const name = self.readAttrName();
            if (name.len == 0) {
                // Not a name char and not a tag end: skip one char to make
                // progress (defensive; malformed input).
                self.pos += 1;
                continue;
            }
            var value: []const u8 = "";
            self.skipWhitespace();
            if (self.pos < self.input.len and self.input[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                value = self.readAttrValue();
            }
            try attrs.append(self.arena, .{ .name = name, .value = value });
        }
        return attrs.toOwnedSlice(self.arena);
    }

    fn readAttrName(self: *Tokenizer) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) : (self.pos += 1) {
            const c = self.input[self.pos];
            if (c == '=' or c == '>' or c == '/' or std.ascii.isWhitespace(c)) break;
        }
        return self.input[start..self.pos];
    }

    fn readAttrValue(self: *Tokenizer) []const u8 {
        if (self.pos >= self.input.len) return "";
        const q = self.input[self.pos];
        if (q == '"' or q == '\'') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != q) : (self.pos += 1) {}
            const val = self.input[start..self.pos];
            if (self.pos < self.input.len) self.pos += 1; // closing quote
            return val;
        }
        // Unquoted value: up to whitespace or tag end.
        const start = self.pos;
        while (self.pos < self.input.len) : (self.pos += 1) {
            const c = self.input[self.pos];
            if (c == '>' or c == '/' or std.ascii.isWhitespace(c)) break;
        }
        return self.input[start..self.pos];
    }

    /// Consume the tag-closing `>` (and a preceding `/` for self-closing).
    /// Returns whether the tag was self-closing.
    fn consumeTagEnd(self: *Tokenizer) bool {
        self.skipWhitespace();
        var self_closing = false;
        if (self.pos < self.input.len and self.input[self.pos] == '/') {
            self_closing = true;
            self.pos += 1;
        }
        if (self.pos < self.input.len and self.input[self.pos] == '>') self.pos += 1;
        return self_closing;
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) : (self.pos += 1) {}
    }

    fn skipTo(self: *Tokenizer, ch: u8) void {
        while (self.pos < self.input.len and self.input[self.pos] != ch) : (self.pos += 1) {}
        if (self.pos < self.input.len) self.pos += 1; // consume the delimiter
    }
};

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}
fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

// ---------------------------------------------------------------------------
// DOM
// ---------------------------------------------------------------------------

/// A DOM node. `element` nodes carry a tag, attributes and children; `text`
/// nodes carry character data. Every node except the document root carries a
/// `parent` pointer so ancestor walks (descendant-combinator matching) are O(1)
/// per step.
pub const Node = struct {
    parent: ?*Node,
    data: Data,

    pub const Data = union(enum) {
        element: Element,
        text: []const u8,
    };

    pub const Element = struct {
        tag: []const u8,
        attrs: []const Attr,
        children: std.ArrayList(*Node),
    };

    /// Convenience: the value of attribute `name` on an element node, or `null`.
    pub fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        switch (self.data) {
            .element => |el| {
                for (el.attrs) |a| {
                    if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
                }
                return null;
            },
            .text => return null,
        }
    }

    pub fn isElement(self: *const Node, tag: []const u8) bool {
        return switch (self.data) {
            .element => |el| std.ascii.eqlIgnoreCase(el.tag, tag),
            .text => false,
        };
    }
};

/// A parsed document. Owns every node via `arena`; call `deinit` to free them
/// all at once. `root` is a synthetic document node whose children are the
/// top-level parsed nodes.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// The top-level nodes (children of the synthetic root).
    pub fn children(self: *const Document) []const *Node {
        return self.root.data.element.children.items;
    }
};

// ---------------------------------------------------------------------------
// TreeBuilder: consumes tokens, enforces the allowlist, builds the DOM.
// ---------------------------------------------------------------------------

/// Consumes a `Token` stream and builds a `Document`, enforcing the element +
/// attribute allowlist and pushing `non_allowlisted_element` diagnostics. This
/// is where the subset POLICY lives; the tokenizer is policy-free.
const TreeBuilder = struct {
    arena: std.mem.Allocator,
    diag: *Diagnostics,
    gpa: std.mem.Allocator,
    root: *Node,
    /// The open-element stack. Each entry is either a real DOM element (kept in
    /// the tree) or a SKIP marker for a non-allowlisted element (present only so
    /// its matching end tag is consumed and its direct text is suppressed). The
    /// synthetic document root is the bottom (real) entry.
    stack: std.ArrayList(Open),

    const Open = union(enum) {
        real: *Node,
        /// A skipped non-allowlisted element, remembered by tag name so its end
        /// tag can be matched.
        skip: []const u8,
    };

    /// The nearest REAL open element (the insertion parent). Text and new
    /// elements attach here; skip markers above it are invisible in the tree.
    fn current(self: *TreeBuilder) *Node {
        var i: usize = self.stack.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.stack.items[i]) {
                .real => |n| return n,
                .skip => {},
            }
        }
        return self.root;
    }

    /// Whether the innermost currently-open element is a skipped one (so direct
    /// text is that skipped element's content and must be dropped).
    fn insideSkip(self: *TreeBuilder) bool {
        if (self.stack.items.len == 0) return false;
        return self.stack.items[self.stack.items.len - 1] == .skip;
    }

    fn newNode(self: *TreeBuilder, parent: ?*Node, data: Node.Data) !*Node {
        const n = try self.arena.create(Node);
        n.* = .{ .parent = parent, .data = data };
        return n;
    }

    fn appendChild(self: *TreeBuilder, parent: *Node, child: *Node) !void {
        try parent.data.element.children.append(self.arena, child);
    }

    /// Only allowlisted attributes are kept on the DOM; the rest are dropped.
    fn filterAttrs(self: *TreeBuilder, tag: []const u8, attrs: []const Attr) ![]const Attr {
        var kept: std.ArrayList(Attr) = .empty;
        for (attrs) |a| {
            if (isAllowlistedAttr(tag, a.name)) try kept.append(self.arena, a);
        }
        return kept.toOwnedSlice(self.arena);
    }

    fn handleStartTag(self: *TreeBuilder, t: Token.StartTag) !void {
        if (!isAllowlistedElement(t.name)) {
            try self.diag.add(self.gpa, .warning, .non_allowlisted_element, t.span, t.name);
            // Skip the element itself. If it is non-void and not self-closing,
            // push a MARKER so its matching end tag is consumed without popping
            // a real element; its allowlisted descendants attach to the current
            // parent (they are handled by the normal loop against `current()`).
            if (!t.self_closing and !isVoidElement(t.name)) {
                try self.stack.append(self.gpa, .{ .skip = t.name });
            }
            return;
        }

        const parent = self.current();
        const attrs = try self.filterAttrs(t.name, t.attrs);
        const el = try self.newNode(parent, .{ .element = .{
            .tag = t.name,
            .attrs = attrs,
            .children = .empty,
        } });
        try self.appendChild(parent, el);

        if (!t.self_closing and !isVoidElement(t.name)) {
            try self.stack.append(self.gpa, .{ .real = el });
        }
    }

    fn handleEndTag(self: *TreeBuilder, t: Token.EndTag) !void {
        // Pop back to the matching open entry (real or skip), if any (tolerant
        // of mis-nesting: search from the top). The document root (index 0) is
        // never popped.
        var i: usize = self.stack.items.len;
        while (i > 1) {
            i -= 1;
            const matches = switch (self.stack.items[i]) {
                .real => |n| n.isElement(t.name),
                .skip => |name| std.ascii.eqlIgnoreCase(name, t.name),
            };
            if (matches) {
                self.stack.shrinkRetainingCapacity(i);
                return;
            }
        }
        // No matching open element: ignore the stray end tag.
    }

    fn handleText(self: *TreeBuilder, data: []const u8) !void {
        // Text that is DIRECT content of a skipped (non-allowlisted) element is
        // that element's content, not the surviving parent's, so it is dropped
        // with the element. Allowlisted element descendants still survive (they
        // are attached against `current()` in `handleStartTag`).
        if (self.insideSkip()) return;
        const parent = self.current();
        const node = try self.newNode(parent, .{ .text = data });
        try self.appendChild(parent, node);
    }
};

/// Parse `input` into a `Document`, reporting non-allowlisted elements through
/// `diag`. The returned `Document` owns its nodes; call `deinit` on it. `input`
/// must outlive the document (node text/attribute slices borrow from it).
///
/// This is the DOM seam consumers should test against: fixture HTML in, assert
/// the DOM structure and the collected diagnostic codes.
pub fn parse(gpa: std.mem.Allocator, input: []const u8, diag: *Diagnostics) !Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    // Tokenize.
    var tz = Tokenizer.init(aa, input);
    const tokens = try tz.tokenize();

    // Synthetic document root.
    const root = try aa.create(Node);
    root.* = .{ .parent = null, .data = .{ .element = .{
        .tag = "#document",
        .attrs = &.{},
        .children = .empty,
    } } };

    var tb: TreeBuilder = .{
        .arena = aa,
        .diag = diag,
        .gpa = gpa,
        .root = root,
        .stack = .empty,
    };
    defer tb.stack.deinit(gpa);
    try tb.stack.append(gpa, .{ .real = root });

    for (tokens) |tok| {
        switch (tok) {
            .start_tag => |t| try tb.handleStartTag(t),
            .end_tag => |t| try tb.handleEndTag(t),
            .text => |t| try tb.handleText(t.data),
            .comment => {}, // comments are not part of the v0 DOM
        }
    }

    return .{ .arena = arena, .root = root };
}

// ===========================================================================
// Tests — at the DOM seam (fixture HTML in, assert DOM + diagnostic codes).
// ===========================================================================

const testing = std.testing;

/// Collect the diagnostic codes from a sink, in order, for compact assertions.
fn codesOf(diag: *const Diagnostics, buf: []diagnostics.Code) []diagnostics.Code {
    const es = diag.entries();
    for (es, 0..) |e, i| buf[i] = e.code;
    return buf[0..es.len];
}

test "parses a nested element tree with parent pointers" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try parse(gpa, "<div><p>hi</p></div>", &diag);
    defer doc.deinit();

    const top = doc.children();
    try testing.expectEqual(@as(usize, 1), top.len);
    const div = top[0];
    try testing.expect(div.isElement("div"));
    try testing.expectEqual(@as(?*Node, doc.root), div.parent);

    const p = div.data.element.children.items[0];
    try testing.expect(p.isElement("p"));
    // Parent pointer walks back up to the div.
    try testing.expectEqual(@as(?*Node, div), p.parent);

    const text = p.data.element.children.items[0];
    try testing.expectEqualStrings("hi", text.data.text);
    try testing.expectEqual(@as(?*Node, p), text.parent);

    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "captures the style attribute value on the DOM" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try parse(gpa, "<p style=\"color: red\">x</p>", &diag);
    defer doc.deinit();

    const p = doc.children()[0];
    try testing.expectEqualStrings("color: red", p.attr("style").?);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "style block content is captured as raw text (css punctuation intact)" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try parse(gpa, "<style>p { color: red; }</style>", &diag);
    defer doc.deinit();

    const style = doc.children()[0];
    try testing.expect(style.isElement("style"));
    const raw = style.data.element.children.items[0];
    // The `{`, `}`, `:` inside are preserved verbatim as one text node, NOT
    // tokenized as HTML.
    try testing.expectEqualStrings("p { color: red; }", raw.data.text);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "non-allowlisted element emits diagnostic and is skipped but its allowed children survive" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // <script> is out of the subset; <marquee> too. The inner <span> is allowed
    // and should attach to <body> (the skipped elements' parent).
    var doc = try parse(gpa, "<body><script>bad()</script><marquee><span>keep</span></marquee></body>", &diag);
    defer doc.deinit();

    const body = doc.children()[0];
    try testing.expect(body.isElement("body"));
    // Only the <span> survives as a body child (script/marquee skipped).
    const kids = body.data.element.children.items;
    try testing.expectEqual(@as(usize, 1), kids.len);
    try testing.expect(kids[0].isElement("span"));
    try testing.expectEqualStrings("keep", kids[0].data.element.children.items[0].data.text);

    var buf: [8]diagnostics.Code = undefined;
    const codes = codesOf(&diag, &buf);
    try testing.expectEqualSlices(diagnostics.Code, &.{ .non_allowlisted_element, .non_allowlisted_element }, codes);
}

test "non-allowlisted attributes are dropped, allowlisted ones kept" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    {
        var doc = try parse(gpa, "<a href=\"/x\" id=\"n\" onclick=\"evil\">go</a>", &diag);
        defer doc.deinit();
        const a = doc.children()[0];
        try testing.expectEqualStrings("/x", a.attr("href").?);
        try testing.expectEqualStrings("n", a.attr("id").?);
        try testing.expect(a.attr("onclick") == null); // dropped
    }
    {
        // href is `a`-only: it must NOT be kept on a div.
        var doc = try parse(gpa, "<div href=\"/x\">y</div>", &diag);
        defer doc.deinit();
        const div = doc.children()[0];
        try testing.expect(div.attr("href") == null);
    }
}

test "void element br has no children and needs no end tag" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try parse(gpa, "<p>a<br>b</p>", &diag);
    defer doc.deinit();

    const p = doc.children()[0];
    const kids = p.data.element.children.items;
    try testing.expectEqual(@as(usize, 3), kids.len);
    try testing.expectEqualStrings("a", kids[0].data.text);
    try testing.expect(kids[1].isElement("br"));
    try testing.expectEqual(@as(usize, 0), kids[1].data.element.children.items.len);
    try testing.expectEqualStrings("b", kids[2].data.text);
}

test "comments and doctype are not part of the DOM" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try parse(gpa, "<!doctype html><!-- hi --><div>x</div>", &diag);
    defer doc.deinit();

    const top = doc.children();
    try testing.expectEqual(@as(usize, 1), top.len);
    try testing.expect(top[0].isElement("div"));
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

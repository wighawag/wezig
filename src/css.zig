//! The v0 CSS parser + cascade: parse a FIXED, documented subset of CSS and run
//! the REAL cascade algorithm to attach computed styles to DOM nodes. This is
//! NOT a CSS-conformant engine; the property/selector subsets are explicit
//! allowlists and anything outside them is reported through the `Diagnostics`
//! sink rather than handled.
//!
//! ## Seams (see `docs/adr/0001-...`)
//!
//! Two PARSER entry points share one declaration parser:
//!   - `parseStylesheet(text)` — for `<style>` blocks (and external CSS later):
//!     a list of `rule { declarations }` blocks.
//!   - `parseDeclarationList(text)` — for the `style=""` attribute: a bare
//!     declaration list with no selector.
//!
//! Selector matching goes through a `Selector` AST + matcher (`matches`) so new
//! selector kinds (child/sibling/attribute/pseudo) are ADDITIVE later: a new
//! `Component`/`Combinator` variant, not a re-shaped matcher. The v0 set is
//! type / `.class` / `#id` / universal `*` / the descendant combinator /
//! grouping (`a, b`); everything else emits `unsupported_selector` and the rule
//! is skipped.
//!
//! The cascade is the REAL algorithm on a small property set (`cascade`):
//!   origin tier (inline `style=""` beats author `<style>` rules)
//!     → selector specificity (the id/class/type triple, compared left-to-right)
//!     → source order (later declaration wins on a tie).
//! Then inheritance (each supported property carries an `inherited` flag), then
//! initial values for anything still unset, plus a HARDCODED per-element default
//! `display` table (NOT a full UA-stylesheet cascade tier).
//!
//! Consumers should test at the COMPUTED-STYLE seam: fixture HTML + CSS in,
//! assert the `ComputedStyle` on specific nodes AND the collected diagnostic
//! codes, NOT the internal parser structures.
//!
//! Decisions (see the task done record `work/tasks/*/css-parse-and-cascade.md`
//! for the full why + alternatives):
//!   - SUPPORTED PROPERTY SET (small, each with an explicit `inherited` flag;
//!     the seed the `document-v0-subset-limits` task reads):
//!       display          (inherited: false)
//!       color            (inherited: true)
//!       background-color (inherited: false)
//!       font-family      (inherited: true)
//!       font-size        (inherited: true)
//!       font-weight      (inherited: true)
//!       width            (inherited: false)
//!       height           (inherited: false)
//!       margin           (inherited: false)
//!       padding          (inherited: false)
//!     Anything else emits `unknown_property` and is ignored.
//!   - Values are carried as RAW trimmed strings in v0. The cascade resolves
//!     WHICH declaration wins (origin/specificity/order) and inheritance; it
//!     does NOT parse lengths/colours. Unit/`%` interpretation (and the
//!     `unsupported_unit` diagnostic) is the LAYOUT task's job — layout reads
//!     these computed strings. This keeps the cascade about the cascade.
//!   - SPECIFICITY is the classic (id, class, type) triple. `#id` adds to id,
//!     `.class` to class, a type name to type; `*` adds nothing. A compound
//!     selector (`div.foo#bar`) sums its parts; a descendant selector
//!     (`a b`) sums across its compounds. Triples compare left-to-right
//!     (id, then class, then type); an exact tie falls through to source order.
//!   - `!important` is NOT supported: a declaration carrying it emits
//!     `unsupported_important` and the declaration is IGNORED entirely (the
//!     `!important` marker is not stripped-and-kept — the whole declaration is
//!     dropped, so no accidental normal-priority application).
//!   - DEFAULT `display` TABLE (hardcoded per element; NOT a UA cascade tier).
//!     It seeds each element's `display` BEFORE the cascade, so an author rule
//!     or inline style still overrides it normally:
//!       block:  html body div p h1 h2 h3 h4 h5 h6 ul ol li
//!       inline: span a strong em b i br
//!     Any element not in the table defaults to `inline` (the CSS initial).

const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const html = @import("html.zig");

const Diagnostics = diagnostics.Diagnostics;
const Span = diagnostics.Span;
const Node = html.Node;

// ---------------------------------------------------------------------------
// Supported property set (the small v0 allowlist; each carries `inherited`).
// ---------------------------------------------------------------------------

/// A supported CSS property. New variants are ADDITIVE (append to keep any
/// future `@intFromEnum` stable). Anything not here emits `unknown_property`.
pub const Property = enum {
    display,
    color,
    background_color,
    font_family,
    font_size,
    font_weight,
    width,
    height,
    margin,
    padding,

    /// The number of supported properties (for fixed-size computed maps).
    pub const count = @typeInfo(Property).@"enum".fields.len;

    /// Whether this property inherits from the parent element by default.
    /// This flag is the authoritative source for the limits doc.
    pub fn inherited(self: Property) bool {
        return switch (self) {
            .color, .font_family, .font_size, .font_weight => true,
            .display, .background_color, .width, .height, .margin, .padding => false,
        };
    }

    /// The CSS initial value for a property still unset after cascade +
    /// inheritance. `display`'s initial is `inline`, but the per-element default
    /// table (see `defaultDisplay`) seeds it BEFORE the cascade, so this initial
    /// is only a fallback for elements not in the table.
    pub fn initialValue(self: Property) []const u8 {
        return switch (self) {
            .display => "inline",
            .color => "black",
            .background_color => "transparent",
            .font_family => "serif",
            .font_size => "16px",
            .font_weight => "normal",
            .width, .height => "auto",
            .margin, .padding => "0",
        };
    }

    /// Map a lower-cased CSS property name to a `Property`, or `null` if it is
    /// outside the supported set.
    pub fn fromName(name: []const u8) ?Property {
        const table = .{
            .{ "display", Property.display },
            .{ "color", Property.color },
            .{ "background-color", Property.background_color },
            .{ "font-family", Property.font_family },
            .{ "font-size", Property.font_size },
            .{ "font-weight", Property.font_weight },
            .{ "width", Property.width },
            .{ "height", Property.height },
            .{ "margin", Property.margin },
            .{ "padding", Property.padding },
        };
        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
        }
        return null;
    }
};

/// The hardcoded per-element default `display` table (NOT a UA cascade tier).
/// Seeds each element's `display` before the cascade runs, so author/inline
/// rules override it normally. Elements not listed default to `inline`.
pub fn defaultDisplay(tag: []const u8) []const u8 {
    const block = [_][]const u8{
        "html", "body", "div", "p",  "h1", "h2", "h3",
        "h4",   "h5",   "h6",  "ul", "ol", "li",
    };
    for (block) |b| {
        if (std.ascii.eqlIgnoreCase(tag, b)) return "block";
    }
    return "inline"; // span, a, strong, em, b, i, br, and anything unlisted
}

// ---------------------------------------------------------------------------
// Computed style (the OUTPUT seam consumers test against).
// ---------------------------------------------------------------------------

/// The resolved computed styles for one element: exactly one value per
/// supported property. Values are raw trimmed strings in v0 (layout resolves
/// lengths/units). Attached to element nodes by `cascade` and read back with
/// `get`.
pub const ComputedStyle = struct {
    values: [Property.count][]const u8,

    /// The computed value of `prop` (always present: cascade fills every
    /// property from the winning declaration, inheritance, or the initial).
    pub fn get(self: *const ComputedStyle, prop: Property) []const u8 {
        return self.values[@intFromEnum(prop)];
    }
};

// ---------------------------------------------------------------------------
// Selector AST (behind a seam so new kinds are additive).
// ---------------------------------------------------------------------------

/// One simple selector component in a compound. New kinds (attribute, pseudo,
/// …) append here; the matcher gains a case, callers do not change.
pub const Component = union(enum) {
    universal, // *
    type_name: []const u8, // div
    class: []const u8, // .foo
    id: []const u8, // #bar
};

/// A compound selector: a run of components with no combinator between them
/// (`div.foo#bar`). All components must match the same element.
pub const Compound = struct {
    components: []const Component,
};

/// A complex selector: compounds joined by combinators. v0 has only the
/// descendant combinator (whitespace), so this is a list of compounds where
/// each must match an ANCESTOR-or-self chain: the last compound matches the
/// element, each earlier compound matches some ancestor, in order. New
/// combinators (child `>`, sibling `+`/`~`) become a per-step combinator field.
pub const Selector = struct {
    /// Ordered ancestor→…→subject compounds (descendant-joined in v0).
    compounds: []const Compound,

    /// The (id, class, type) specificity triple for this selector.
    pub fn specificity(self: *const Selector) Specificity {
        var s = Specificity{ .id = 0, .class = 0, .type = 0 };
        for (self.compounds) |c| {
            for (c.components) |comp| {
                switch (comp) {
                    .id => s.id += 1,
                    .class => s.class += 1,
                    .type_name => s.type += 1,
                    .universal => {},
                }
            }
        }
        return s;
    }
};

/// The classic specificity triple, compared left-to-right (id, then class,
/// then type).
pub const Specificity = struct {
    id: u32,
    class: u32,
    type: u32,

    /// `.lt`/`.eq`/`.gt` ordering, id-major then class then type.
    pub fn order(a: Specificity, b: Specificity) std.math.Order {
        if (a.id != b.id) return std.math.order(a.id, b.id);
        if (a.class != b.class) return std.math.order(a.class, b.class);
        return std.math.order(a.type, b.type);
    }
};

// ---------------------------------------------------------------------------
// Declarations + rules.
// ---------------------------------------------------------------------------

/// One `property: value` declaration, already resolved to a supported
/// `Property`. Values are raw trimmed strings.
pub const Declaration = struct {
    property: Property,
    value: []const u8,
};

/// One parsed style rule: a group of selectors sharing a declaration block.
/// (`a, b { ... }` becomes ONE rule with two selectors; each selector keeps its
/// own specificity for the cascade.)
pub const Rule = struct {
    selectors: []const Selector,
    declarations: []const Declaration,
};

/// A parsed stylesheet: an ordered list of rules (source order preserved for
/// the cascade tie-break).
pub const Stylesheet = struct {
    rules: []const Rule,
};

// ---------------------------------------------------------------------------
// Parsing.
// ---------------------------------------------------------------------------

/// Trim ASCII whitespace from both ends.
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0c");
}

/// Parse the value side of a declaration, honouring the v0 rules: an
/// `!important` marker emits `unsupported_important` and makes the whole
/// declaration drop (returns `null`). Otherwise returns the trimmed value.
fn parseValue(
    value_raw: []const u8,
    diag: *Diagnostics,
    gpa: std.mem.Allocator,
    span: Span,
) !?[]const u8 {
    const v = trim(value_raw);
    // Detect `!important` (case-insensitive, possibly with whitespace before
    // `important`). v0 has no important tier: drop the declaration.
    if (std.mem.indexOfScalar(u8, v, '!')) |bang| {
        const after = trim(v[bang + 1 ..]);
        if (std.ascii.startsWithIgnoreCase(after, "important")) {
            try diag.add(gpa, .warning, .unsupported_important, span, "!important is not supported in v0");
            return null;
        }
    }
    return v;
}

/// Parse ONE `property: value;` declaration into `out`, pushing diagnostics for
/// unknown properties / `!important`. A malformed (no colon) declaration is
/// silently skipped in v0. `base` is the byte offset of `text` within the
/// original input, for correct diagnostic spans.
fn parseOneDeclaration(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    text: []const u8,
    base: usize,
    diag: *Diagnostics,
    out: *std.ArrayList(Declaration),
) !void {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return;
    const name = trim(text[0..colon]);
    if (name.len == 0) return;
    const span = Span{ .start = base, .end = base + text.len };

    const prop = Property.fromName(name) orelse {
        try diag.add(gpa, .warning, .unknown_property, span, "unknown CSS property");
        return;
    };
    const value = (try parseValue(text[colon + 1 ..], diag, gpa, span)) orelse return;
    if (value.len == 0) return;
    try out.append(arena, .{ .property = prop, .value = value });
}

/// Parse a bare declaration list (the `style=""` attribute body, or the inside
/// of a rule's `{ }`). `base` is the byte offset of `text` in the original
/// input for spans.
fn parseDeclarationsInner(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    text: []const u8,
    base: usize,
    diag: *Diagnostics,
) ![]const Declaration {
    var decls: std.ArrayList(Declaration) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const semi = std.mem.indexOfScalarPos(u8, text, i, ';') orelse text.len;
        const chunk = text[i..semi];
        if (trim(chunk).len != 0) {
            try parseOneDeclaration(arena, gpa, chunk, base + i, diag, &decls);
        }
        i = semi + 1;
    }
    return decls.toOwnedSlice(arena);
}

/// PUBLIC entry point for `style=""`: parse a bare declaration list.
pub fn parseDeclarationList(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    text: []const u8,
    diag: *Diagnostics,
) ![]const Declaration {
    return parseDeclarationsInner(arena, gpa, text, 0, diag);
}

/// Parse one compound selector (`div.foo#bar` or `*`). Returns `null` (and
/// emits `unsupported_selector`) if it contains any unsupported syntax
/// (combinators other than descendant, attribute/pseudo, etc.).
fn parseCompound(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    text: []const u8,
    span: Span,
    diag: *Diagnostics,
) !?Compound {
    var comps: std.ArrayList(Component) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '*' => {
                try comps.append(arena, .universal);
                i += 1;
            },
            '.', '#' => {
                i += 1;
                const start = i;
                while (i < text.len and isIdentChar(text[i])) : (i += 1) {}
                if (i == start) {
                    try diag.add(gpa, .warning, .unsupported_selector, span, "empty class/id selector");
                    return null;
                }
                const name = text[start..i];
                try comps.append(arena, if (c == '.') .{ .class = name } else .{ .id = name });
            },
            else => {
                if (!isIdentStart(c)) {
                    // Unsupported syntax: attribute `[`, pseudo `:`, combinators
                    // `>`/`+`/`~`, etc.
                    try diag.add(gpa, .warning, .unsupported_selector, span, "unsupported selector syntax");
                    return null;
                }
                const start = i;
                while (i < text.len and isIdentChar(text[i])) : (i += 1) {}
                try comps.append(arena, .{ .type_name = text[start..i] });
            },
        }
    }
    if (comps.items.len == 0) return null;
    return Compound{ .components = try comps.toOwnedSlice(arena) };
}

/// Parse one complex selector: whitespace-separated compounds (descendant
/// combinator only in v0). Emits `unsupported_selector` and returns `null` on
/// any unsupported piece.
fn parseSelector(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    text: []const u8,
    span: Span,
    diag: *Diagnostics,
) !?Selector {
    var compounds: std.ArrayList(Compound) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n\x0c");
    while (it.next()) |piece| {
        // A bare combinator token (`>`, `+`, `~`) between compounds is
        // unsupported in v0.
        if (piece.len == 1 and (piece[0] == '>' or piece[0] == '+' or piece[0] == '~')) {
            try diag.add(gpa, .warning, .unsupported_selector, span, "unsupported combinator");
            return null;
        }
        const compound = (try parseCompound(arena, gpa, piece, span, diag)) orelse return null;
        try compounds.append(arena, compound);
    }
    if (compounds.items.len == 0) return null;
    return Selector{ .compounds = try compounds.toOwnedSlice(arena) };
}

/// Parse a selector list (`a, b, c`) into concrete selectors. Any group member
/// that is unsupported is dropped (with an `unsupported_selector` diagnostic);
/// if ALL members are unsupported the rule has no selectors and is skipped by
/// the caller.
fn parseSelectorList(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    text: []const u8,
    base: usize,
    diag: *Diagnostics,
) ![]const Selector {
    var sels: std.ArrayList(Selector) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const comma = std.mem.indexOfScalarPos(u8, text, i, ',') orelse text.len;
        const piece = text[i..comma];
        const span = Span{ .start = base + i, .end = base + comma };
        if (trim(piece).len != 0) {
            if (try parseSelector(arena, gpa, trim(piece), span, diag)) |sel| {
                try sels.append(arena, sel);
            }
        }
        i = comma + 1;
    }
    return sels.toOwnedSlice(arena);
}

/// PUBLIC entry point for `<style>` blocks (and external CSS later): parse a
/// stylesheet of `selectors { declarations }` rules.
pub fn parseStylesheet(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    text: []const u8,
    diag: *Diagnostics,
) !Stylesheet {
    var rules: std.ArrayList(Rule) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const open = std.mem.indexOfScalarPos(u8, text, i, '{') orelse break;
        const close = std.mem.indexOfScalarPos(u8, text, open + 1, '}') orelse text.len;

        const selector_text = text[i..open];
        const decl_text = text[open + 1 .. @min(close, text.len)];

        const selectors = try parseSelectorList(arena, gpa, selector_text, i, diag);
        const declarations = try parseDeclarationsInner(arena, gpa, decl_text, open + 1, diag);

        // A rule with no surviving selectors (all unsupported) is skipped.
        if (selectors.len != 0) {
            try rules.append(arena, .{ .selectors = selectors, .declarations = declarations });
        }
        i = if (close < text.len) close + 1 else text.len;
    }
    return .{ .rules = try rules.toOwnedSlice(arena) };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-';
}
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

// ---------------------------------------------------------------------------
// Selector matching (walks DOM parent pointers for the descendant combinator).
// ---------------------------------------------------------------------------

/// Whether one compound matches a single element node.
fn compoundMatches(node: *const Node, compound: Compound) bool {
    const el = switch (node.data) {
        .element => |e| e,
        .text => return false,
    };
    for (compound.components) |comp| {
        switch (comp) {
            .universal => {},
            .type_name => |name| if (!std.ascii.eqlIgnoreCase(el.tag, name)) return false,
            .id => |name| {
                const id = node.attr("id") orelse return false;
                if (!std.mem.eql(u8, id, name)) return false;
            },
            .class => |name| if (!hasClass(node, name)) return false,
        }
    }
    return true;
}

/// Whether `node`'s `class` attribute contains the whitespace-separated token
/// `name`.
fn hasClass(node: *const Node, name: []const u8) bool {
    const classes = node.attr("class") orelse return false;
    var it = std.mem.tokenizeAny(u8, classes, " \t\r\n\x0c");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, name)) return true;
    }
    return false;
}

/// Whether the complex selector matches `node` as its subject. The last
/// compound must match `node`; each earlier compound must match some ancestor,
/// preserving order (descendant combinator). Walks `parent` pointers.
pub fn matches(node: *const Node, selector: Selector) bool {
    const n = selector.compounds.len;
    // Subject compound must match the element itself.
    if (!compoundMatches(node, selector.compounds[n - 1])) return false;
    if (n == 1) return true;

    // Remaining compounds (right-to-left) must each match an ancestor, in
    // order. Greedy walk up the parent chain.
    var idx: usize = n - 1; // index of the next compound to satisfy (exclusive)
    var cur: ?*const Node = node.parent;
    while (idx > 0) {
        idx -= 1;
        const want = selector.compounds[idx];
        var found = false;
        while (cur) |anc| {
            cur = anc.parent;
            if (compoundMatches(anc, want)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Cascade.
// ---------------------------------------------------------------------------

/// The origin tier for a matched declaration. Inline `style=""` beats author
/// `<style>` rules. New tiers (user-agent, user) would slot in with explicit
/// ordering.
const Origin = enum(u2) {
    author = 0,
    inline_style = 1,
};

/// One declaration in the running for a property on one element, with its
/// cascade sort key (origin → specificity → source order).
const Candidate = struct {
    value: []const u8,
    origin: Origin,
    specificity: Specificity,
    order: usize,

    /// Whether `self` wins over `other` (higher priority).
    fn beats(self: Candidate, other: Candidate) bool {
        if (self.origin != other.origin) return @intFromEnum(self.origin) > @intFromEnum(other.origin);
        switch (self.specificity.order(other.specificity)) {
            .gt => return true,
            .lt => return false,
            .eq => return self.order >= other.order, // later source wins ties
        }
    }
};

/// The styled document: a computed style per element node, keyed by node
/// pointer. The `ComputedStyle` records live in an owned arena so their
/// pointers are STABLE (inheritance passes a parent's `*ComputedStyle` down the
/// recursion; the map itself may rehash, so we must not hand out map value
/// pointers). `deinit` frees both the map and the arena.
pub const StyledDocument = struct {
    styles: std.AutoHashMapUnmanaged(*const Node, *ComputedStyle),
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *StyledDocument) void {
        self.styles.deinit(self.gpa);
        self.arena.deinit();
    }

    /// The computed style for `node`, or `null` if `node` is not a styled
    /// element (e.g. a text node).
    pub fn styleFor(self: *const StyledDocument, node: *const Node) ?*const ComputedStyle {
        return self.styles.get(node);
    }
};

/// Run the real cascade over `doc` using the author `sheet` and each element's
/// inline `style=""`. Returns computed styles attached per element node.
///
/// This is the COMPUTED-STYLE seam: callers give HTML (a parsed `Document`) +
/// CSS (a parsed `Stylesheet`) and read back `ComputedStyle` per node.
pub fn cascade(
    gpa: std.mem.Allocator,
    doc: *const html.Document,
    sheet: Stylesheet,
    diag: *Diagnostics,
) !StyledDocument {
    var styled = StyledDocument{
        .styles = .empty,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .gpa = gpa,
    };
    errdefer styled.deinit();

    // A scratch arena for parsing inline `style=""` declarations.
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    try styleSubtree(gpa, scratch, &styled, doc.root, null, sheet, diag);
    return styled;
}

/// Recursively compute styles for `node` and its element descendants,
/// pre-order so a parent's computed style is available to inherit from.
/// `parent_style` is the already-computed style of the nearest element ancestor
/// (null at the root).
fn styleSubtree(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    styled: *StyledDocument,
    node: *const Node,
    parent_style: ?*const ComputedStyle,
    sheet: Stylesheet,
    diag: *Diagnostics,
) !void {
    var next_parent = parent_style;
    switch (node.data) {
        .element => |el| {
            // The synthetic `#document` root is not a real element; skip
            // computing a style for it but still recurse.
            if (!std.mem.eql(u8, el.tag, "#document")) {
                const computed = try styled.arena.allocator().create(ComputedStyle);
                computed.* = try computeStyle(gpa, arena, node, el.tag, parent_style, sheet, diag);
                try styled.styles.put(gpa, node, computed);
                next_parent = computed;
            }
        },
        .text => return,
    }
    switch (node.data) {
        .element => |el| for (el.children.items) |child| {
            try styleSubtree(gpa, arena, styled, child, next_parent, sheet, diag);
        },
        .text => {},
    }
}

/// Compute one element's `ComputedStyle`: gather winning declarations by the
/// cascade, then apply inheritance / initial values / the default-`display`
/// seed.
fn computeStyle(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    node: *const Node,
    tag: []const u8,
    parent_style: ?*const ComputedStyle,
    sheet: Stylesheet,
    diag: *Diagnostics,
) !ComputedStyle {
    // Per-property winning candidate (null = no declaration matched).
    var winners = [_]?Candidate{null} ** Property.count;
    var order: usize = 0;

    // 1) Author `<style>` rules, in source order.
    for (sheet.rules) |rule| {
        // Best specificity among this rule's selectors that match.
        var matched = false;
        var best_spec = Specificity{ .id = 0, .class = 0, .type = 0 };
        for (rule.selectors) |sel| {
            if (matches(node, sel)) {
                const spec = sel.specificity();
                if (!matched or spec.order(best_spec) == .gt) best_spec = spec;
                matched = true;
            }
        }
        if (!matched) {
            order += rule.declarations.len;
            continue;
        }
        for (rule.declarations) |decl| {
            considerCandidate(&winners, decl, .{
                .value = decl.value,
                .origin = .author,
                .specificity = best_spec,
                .order = order,
            });
            order += 1;
        }
    }

    // 2) Inline `style=""` (highest origin tier).
    if (node.attr("style")) |inline_css| {
        const inline_decls = try parseDeclarationList(arena, gpa, inline_css, diag);
        for (inline_decls) |decl| {
            considerCandidate(&winners, decl, .{
                .value = decl.value,
                .origin = .inline_style,
                .specificity = .{ .id = 0, .class = 0, .type = 0 },
                .order = order,
            });
            order += 1;
        }
    }

    // 3) Resolve every property: winner → inheritance → default-display → initial.
    var computed: ComputedStyle = undefined;
    inline for (comptime std.enums.values(Property)) |prop| {
        const i = @intFromEnum(prop);
        if (winners[i]) |w| {
            computed.values[i] = w.value;
        } else if (prop.inherited() and parent_style != null) {
            computed.values[i] = parent_style.?.get(prop);
        } else if (prop == .display) {
            computed.values[i] = defaultDisplay(tag);
        } else {
            computed.values[i] = prop.initialValue();
        }
    }
    return computed;
}

/// Record `cand` as the winner for `decl.property` if it beats the current one.
fn considerCandidate(winners: *[Property.count]?Candidate, decl: Declaration, cand: Candidate) void {
    const i = @intFromEnum(decl.property);
    if (winners[i]) |cur| {
        if (cand.beats(cur)) winners[i] = cand;
    } else {
        winners[i] = cand;
    }
}

/// Convenience one-shot: parse `<style>` text into a stylesheet and cascade it
/// (plus inline styles) onto `doc`. The typical entry the layout task calls.
pub fn styleDocument(
    gpa: std.mem.Allocator,
    doc: *const html.Document,
    stylesheet_text: []const u8,
    diag: *Diagnostics,
) !StyledDocument {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sheet = try parseStylesheet(arena_state.allocator(), gpa, stylesheet_text, diag);
    return cascade(gpa, doc, sheet, diag);
}

// ===========================================================================
// Tests — at the COMPUTED-STYLE seam (HTML + CSS fixtures in; assert computed
// styles on target nodes AND collected diagnostic codes).
// ===========================================================================

const testing = std.testing;

/// Collect diagnostic codes in order for compact assertions.
fn codesOf(diag: *const Diagnostics, buf: []diagnostics.Code) []diagnostics.Code {
    const es = diag.entries();
    for (es, 0..) |e, i| buf[i] = e.code;
    return buf[0..es.len];
}

/// Find the first element with the given tag in a pre-order walk (test helper).
fn firstByTag(node: *const Node, tag: []const u8) ?*const Node {
    switch (node.data) {
        .element => |el| {
            if (std.mem.eql(u8, el.tag, tag)) return node;
            for (el.children.items) |child| {
                if (firstByTag(child, tag)) |found| return found;
            }
        },
        .text => {},
    }
    return null;
}

test "type rule sets a property and inheritance flows color to descendants" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try html.parse(gpa, "<body><p>hi <span>x</span></p></body>", &diag);
    defer doc.deinit();

    var styled = try styleDocument(gpa, &doc, "p { color: red; }", &diag);
    defer styled.deinit();

    const p = firstByTag(doc.root, "p").?;
    const span = firstByTag(doc.root, "span").?;
    // color is inherited: the span (no rule of its own) inherits red from p.
    try testing.expectEqualStrings("red", styled.styleFor(p).?.get(.color));
    try testing.expectEqualStrings("red", styled.styleFor(span).?.get(.color));
    // background-color is NOT inherited: span falls back to the initial.
    try testing.expectEqualStrings("transparent", styled.styleFor(span).?.get(.background_color));
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "default display table seeds block vs inline before the cascade" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try html.parse(gpa, "<div><span>x</span></div>", &diag);
    defer doc.deinit();

    var styled = try styleDocument(gpa, &doc, "", &diag);
    defer styled.deinit();

    const div = firstByTag(doc.root, "div").?;
    const span = firstByTag(doc.root, "span").?;
    try testing.expectEqualStrings("block", styled.styleFor(div).?.get(.display));
    try testing.expectEqualStrings("inline", styled.styleFor(span).?.get(.display));
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "inline style beats author rules regardless of specificity" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // Author rule has an #id (high specificity); inline style must still win.
    var doc = try html.parse(gpa, "<p id=\"a\" style=\"color: green\">x</p>", &diag);
    defer doc.deinit();

    var styled = try styleDocument(gpa, &doc, "#a { color: red; }", &diag);
    defer styled.deinit();

    const p = firstByTag(doc.root, "p").?;
    try testing.expectEqualStrings("green", styled.styleFor(p).?.get(.color));
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "specificity: id beats class beats type; source order breaks exact ties" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try html.parse(gpa, "<p id=\"a\" class=\"c\">x</p>", &diag);
    defer doc.deinit();

    // type(red) < class(green) < id(blue); a second id rule later wins the tie.
    const css =
        "p { color: red; } .c { color: green; } #a { color: blue; } #a { color: black; }";
    var styled = try styleDocument(gpa, &doc, css, &diag);
    defer styled.deinit();

    const p = firstByTag(doc.root, "p").?;
    try testing.expectEqualStrings("black", styled.styleFor(p).?.get(.color));
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "descendant combinator matches via ancestor walk; grouping applies to all" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try html.parse(gpa, "<div class=\"box\"><p>in</p></div><h1>t</h1><p>out</p>", &diag);
    defer doc.deinit();

    // Grouping: `h1, .box p` applies to BOTH the h1 AND the p inside .box, but
    // NOT the top-level p (descendant combinator needs a .box ancestor).
    var styled = try styleDocument(gpa, &doc, "h1, .box p { color: red; }", &diag);
    defer styled.deinit();

    // The p inside .box (red) and the h1 (red, via the grouped selector).
    const div = firstByTag(doc.root, "div").?;
    const inner_p = firstByTag(div, "p").?;
    const h1 = firstByTag(doc.root, "h1").?;
    try testing.expectEqualStrings("red", styled.styleFor(inner_p).?.get(.color));
    try testing.expectEqualStrings("red", styled.styleFor(h1).?.get(.color));

    // The out p: walk children of root to find the second p.
    var outer_p: ?*const Node = null;
    for (doc.children()) |top| {
        if (std.mem.eql(u8, switch (top.data) {
            .element => |e| e.tag,
            .text => "",
        }, "p")) outer_p = top;
    }
    try testing.expectEqualStrings("black", styled.styleFor(outer_p.?).?.get(.color));
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "universal selector matches every element" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try html.parse(gpa, "<div><span>x</span></div>", &diag);
    defer doc.deinit();

    var styled = try styleDocument(gpa, &doc, "* { color: purple; }", &diag);
    defer styled.deinit();

    const div = firstByTag(doc.root, "div").?;
    const span = firstByTag(doc.root, "span").?;
    try testing.expectEqualStrings("purple", styled.styleFor(div).?.get(.color));
    try testing.expectEqualStrings("purple", styled.styleFor(span).?.get(.color));
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "unsupported selector emits diagnostic and the rule is skipped" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try html.parse(gpa, "<p>x</p>", &diag);
    defer doc.deinit();

    // `p > span` (child combinator) and `p:hover` (pseudo) are unsupported; the
    // `p` type rule after them still applies.
    const css = "p > span { color: red; } p:hover { color: blue; } p { color: green; }";
    var styled = try styleDocument(gpa, &doc, css, &diag);
    defer styled.deinit();

    const p = firstByTag(doc.root, "p").?;
    try testing.expectEqualStrings("green", styled.styleFor(p).?.get(.color));

    var buf: [8]diagnostics.Code = undefined;
    const codes = codesOf(&diag, &buf);
    try testing.expectEqualSlices(diagnostics.Code, &.{ .unsupported_selector, .unsupported_selector }, codes);
}

test "unknown property emits diagnostic and is ignored" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try html.parse(gpa, "<p>x</p>", &diag);
    defer doc.deinit();

    var styled = try styleDocument(gpa, &doc, "p { wibble: 3; color: red; }", &diag);
    defer styled.deinit();

    const p = firstByTag(doc.root, "p").?;
    try testing.expectEqualStrings("red", styled.styleFor(p).?.get(.color));

    var buf: [8]diagnostics.Code = undefined;
    const codes = codesOf(&diag, &buf);
    try testing.expectEqualSlices(diagnostics.Code, &.{.unknown_property}, codes);
}

test "!important emits diagnostic and the declaration is dropped" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try html.parse(gpa, "<p>x</p>", &diag);
    defer doc.deinit();

    // The !important declaration is dropped entirely, so the earlier normal
    // one is the winner (not the important value at normal priority).
    var styled = try styleDocument(gpa, &doc, "p { color: red; color: blue !important; }", &diag);
    defer styled.deinit();

    const p = firstByTag(doc.root, "p").?;
    try testing.expectEqualStrings("red", styled.styleFor(p).?.get(.color));

    var buf: [8]diagnostics.Code = undefined;
    const codes = codesOf(&diag, &buf);
    try testing.expectEqualSlices(diagnostics.Code, &.{.unsupported_important}, codes);
}

test "parseDeclarationList exists for style-attribute bodies" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const decls = try parseDeclarationList(arena.allocator(), gpa, "color: red; width: 10px", &diag);
    try testing.expectEqual(@as(usize, 2), decls.len);
    try testing.expectEqual(Property.color, decls[0].property);
    try testing.expectEqualStrings("red", decls[0].value);
    try testing.expectEqual(Property.width, decls[1].property);
    try testing.expectEqualStrings("10px", decls[1].value);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "unset non-inherited property takes its initial value" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var doc = try html.parse(gpa, "<p>x</p>", &diag);
    defer doc.deinit();

    var styled = try styleDocument(gpa, &doc, "", &diag);
    defer styled.deinit();

    const p = firstByTag(doc.root, "p").?;
    const s = styled.styleFor(p).?;
    try testing.expectEqualStrings("auto", s.get(.width));
    try testing.expectEqualStrings("0", s.get(.margin));
    try testing.expectEqualStrings("16px", s.get(.font_size));
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "inheritance survives a deep tree (stable computed-style pointers)" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // A deliberately deep chain: enough element nodes to force the style map to
    // rehash mid-cascade, which would invalidate a map value pointer. The leaf
    // must still inherit `color` from the top, proving the parent style pointer
    // stayed valid through the whole walk.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const depth = 64;
    for (0..depth) |_| try buf.appendSlice(gpa, "<div>");
    try buf.appendSlice(gpa, "<span>leaf</span>");
    for (0..depth) |_| try buf.appendSlice(gpa, "</div>");

    var doc = try html.parse(gpa, buf.items, &diag);
    defer doc.deinit();

    var styled = try styleDocument(gpa, &doc, "div { color: teal; }", &diag);
    defer styled.deinit();

    const span = firstByTag(doc.root, "span").?;
    // span has no rule; it inherits color teal down the whole div chain.
    try testing.expectEqualStrings("teal", styled.styleFor(span).?.get(.color));
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "every supported property has an explicit inherited flag" {
    // Guards the property/inherited table the limits doc reads.
    try testing.expect(Property.color.inherited());
    try testing.expect(Property.font_family.inherited());
    try testing.expect(Property.font_size.inherited());
    try testing.expect(Property.font_weight.inherited());
    try testing.expect(!Property.display.inherited());
    try testing.expect(!Property.background_color.inherited());
    try testing.expect(!Property.width.inherited());
    try testing.expect(!Property.height.inherited());
    try testing.expect(!Property.margin.inherited());
    try testing.expect(!Property.padding.inherited());
}

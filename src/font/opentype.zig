//! OpenType font parsing: the tables needed to map characters to glyphs,
//! lay them out and draw their outlines.
//!
//! Supported: TrueType outlines (`glyf`, simple and composite glyphs),
//! `cmap` formats 4 and 12, horizontal metrics, and pair kerning from the
//! GPOS `kern` feature (pair adjustment formats 1 and 2, also through
//! extension lookups). Not supported: CFF outlines, variable fonts (the
//! default instance is used), hinting, and other GSUB/GPOS features.
//!
//! The font data is borrowed, not copied, and every read is bounds-checked,
//! so a malformed font gives errors or missing glyphs rather than crashes.
//!
//! Reference: the OpenType specification (https://learn.microsoft.com/typography/opentype/spec/).

const std = @import("std");

pub const Error = error{ Malformed, Unsupported };

/// Glyph ID 0 is the "missing character" glyph in every font.
pub const missing_glyph: u16 = 0;

fn read(comptime T: type, data: []const u8, offset: usize) Error!T {
    const n = @sizeOf(T);
    if (offset + n > data.len) return error.Malformed;
    return std.mem.readInt(T, data[offset..][0..n], .big);
}

fn sub(data: []const u8, offset: usize, len: usize) Error![]const u8 {
    if (offset > data.len or len > data.len - offset) return error.Malformed;
    return data[offset..][0..len];
}

fn tag(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// An affine transform from font units: x' = a*x + c*y + e, y' = b*x + d*y + f.
pub const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub fn apply(t: Transform, x: f32, y: f32) [2]f32 {
        return .{ t.a * x + t.c * y + t.e, t.b * x + t.d * y + t.f };
    }

    /// `t` applied after `inner`.
    pub fn then(inner: Transform, t: Transform) Transform {
        return .{
            .a = t.a * inner.a + t.c * inner.b,
            .b = t.b * inner.a + t.d * inner.b,
            .c = t.a * inner.c + t.c * inner.d,
            .d = t.b * inner.c + t.d * inner.d,
            .e = t.a * inner.e + t.c * inner.f + t.e,
            .f = t.b * inner.e + t.d * inner.f + t.f,
        };
    }
};

/// A glyph's bounding box in font units (y up).
pub const Box = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

/// One layer of a multi-layer colour glyph (`COLR` / `CPAL`).
pub const ColorLayer = struct {
    glyph: u16,
    /// 0xAARRGGBB from the font's first palette, or null when the layer uses
    /// the text's foreground colour (`palette_index == 0xFFFF`).
    color: ?u32,
};

/// Iterator over the back-to-front layers of a `COLR` v0 base glyph.
pub const ColorLayers = struct {
    font: *const Font,
    first: u16,
    count: u16,
    index: u16 = 0,

    pub fn next(it: *ColorLayers) ?ColorLayer {
        if (it.index >= it.count) return null;
        const layer = it.font.colorLayer(@as(usize, it.first) + it.index) catch return null;
        it.index += 1;
        return layer;
    }
};

pub const Font = struct {
    data: []const u8,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    num_glyphs: u16,
    num_hmetrics: u16,
    long_loca: bool,
    hmtx: []const u8,
    loca: []const u8,
    glyf: []const u8,
    /// The chosen cmap subtable and its format (4 or 12).
    cmap: []const u8,
    cmap_format: u16,
    gpos: []const u8 = &.{},
    /// GPOS lookups of the `kern` feature.
    kern_lookups: [max_kern_lookups]u16 = undefined,
    num_kern_lookups: usize = 0,
    /// Optional colour glyph tables (`COLR` v0 and `CPAL` v0) and `GSUB`
    /// `ccmp` ligature lookups (for multi-codepoint emoji sequences).
    colr: []const u8 = &.{},
    cpal: []const u8 = &.{},
    gsub: []const u8 = &.{},
    ccmp_lookups: [max_kern_lookups]u16 = undefined,
    num_ccmp_lookups: usize = 0,
    /// Optional fallback font (e.g. the system emoji font) consulted when a
    /// codepoint is missing from this font or requests emoji presentation.
    fallback: ?*const Font = null,

    pub const Ligature = struct {
        glyph: u16,
        /// How many additional glyphs from `rest` were consumed.
        consumed: usize,
    };

    const max_kern_lookups = 32;

    pub fn init(data: []const u8) Error!Font {
        const version = try read(u32, data, 0);
        if (version == tag("OTTO")) return error.Unsupported; // CFF outlines
        if (version != 0x00010000 and version != tag("true")) return error.Malformed;
        const num_tables = try read(u16, data, 4);

        var tables: struct {
            head: ?[]const u8 = null,
            hhea: ?[]const u8 = null,
            maxp: ?[]const u8 = null,
            hmtx: ?[]const u8 = null,
            loca: ?[]const u8 = null,
            glyf: ?[]const u8 = null,
            cmap: ?[]const u8 = null,
            gpos: ?[]const u8 = null,
            colr: ?[]const u8 = null,
            cpal: ?[]const u8 = null,
            gsub: ?[]const u8 = null,
        } = .{};
        for (0..num_tables) |i| {
            const rec = 12 + i * 16;
            const t = try read(u32, data, rec);
            const table = try sub(data, try read(u32, data, rec + 8), try read(u32, data, rec + 12));
            if (t == tag("head")) tables.head = table;
            if (t == tag("hhea")) tables.hhea = table;
            if (t == tag("maxp")) tables.maxp = table;
            if (t == tag("hmtx")) tables.hmtx = table;
            if (t == tag("loca")) tables.loca = table;
            if (t == tag("glyf")) tables.glyf = table;
            if (t == tag("cmap")) tables.cmap = table;
            if (t == tag("GPOS")) tables.gpos = table;
            if (t == tag("COLR")) tables.colr = table;
            if (t == tag("CPAL")) tables.cpal = table;
            if (t == tag("GSUB")) tables.gsub = table;
        }
        const head = tables.head orelse return error.Malformed;
        const hhea = tables.hhea orelse return error.Malformed;
        const maxp = tables.maxp orelse return error.Malformed;
        const cmap = tables.cmap orelse return error.Malformed;
        var f: Font = .{
            .data = data,
            .units_per_em = try read(u16, head, 18),
            .long_loca = try read(i16, head, 50) != 0,
            .ascender = try read(i16, hhea, 4),
            .descender = try read(i16, hhea, 6),
            .line_gap = try read(i16, hhea, 8),
            .num_hmetrics = try read(u16, hhea, 34),
            .num_glyphs = try read(u16, maxp, 4),
            .hmtx = tables.hmtx orelse return error.Malformed,
            .loca = tables.loca orelse return error.Unsupported,
            .glyf = tables.glyf orelse return error.Unsupported,
            .cmap = undefined,
            .cmap_format = undefined,
            .colr = tables.colr orelse &.{},
            .cpal = tables.cpal orelse &.{},
        };
        if (f.units_per_em == 0 or f.num_hmetrics == 0) return error.Malformed;
        try f.chooseCmap(cmap);
        if (tables.gpos) |g| f.findKernLookups(g) catch {
            // Kerning is optional; lay out without it.
            f.num_kern_lookups = 0;
        };
        if (tables.gsub) |g| f.findCcmpLookups(g) catch {
            f.num_ccmp_lookups = 0;
        };
        return f;
    }

    /// Prefers a full Unicode subtable (format 12), then the Basic
    /// Multilingual Plane one (format 4).
    fn chooseCmap(f: *Font, cmap: []const u8) Error!void {
        const n = try read(u16, cmap, 2);
        var best: ?[]const u8 = null;
        var best_format: u16 = 0;
        for (0..n) |i| {
            const platform = try read(u16, cmap, 4 + i * 8);
            const encoding = try read(u16, cmap, 6 + i * 8);
            const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
            if (!unicode) continue;
            const offset = try read(u32, cmap, 8 + i * 8);
            if (offset >= cmap.len) return error.Malformed;
            const table = cmap[offset..];
            const format = try read(u16, table, 0);
            if (format == 12 and best_format != 12) {
                best = table;
                best_format = 12;
            } else if (format == 4 and best_format == 0) {
                best = table;
                best_format = 4;
            }
        }
        f.cmap = best orelse return error.Unsupported;
        f.cmap_format = best_format;
    }

    /// The glyph for a Unicode code point, or `missing_glyph`.
    pub fn glyphIndex(f: *const Font, cp: u21) u16 {
        const g = (if (f.cmap_format == 12) f.cmap12(cp) else f.cmap4(cp)) catch return missing_glyph;
        return if (g < f.num_glyphs) g else missing_glyph;
    }

    fn cmap4(f: *const Font, cp: u21) Error!u16 {
        if (cp > 0xffff) return missing_glyph;
        const t = f.cmap;
        const seg_count = (try read(u16, t, 6)) / 2;
        const ends = 14;
        const starts = ends + seg_count * 2 + 2;
        const deltas = starts + seg_count * 2;
        const range_offsets = deltas + seg_count * 2;
        // Binary search for the first segment whose end is >= cp.
        var lo: usize = 0;
        var hi: usize = seg_count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (try read(u16, t, ends + mid * 2) < cp) lo = mid + 1 else hi = mid;
        }
        if (lo == seg_count) return missing_glyph;
        const start = try read(u16, t, starts + lo * 2);
        if (cp < start) return missing_glyph;
        const delta = try read(u16, t, deltas + lo * 2);
        const range_offset = try read(u16, t, range_offsets + lo * 2);
        if (range_offset == 0) return @truncate(cp +% delta);
        const at = range_offsets + lo * 2 + range_offset + (cp - start) * 2;
        const g = try read(u16, t, at);
        return if (g == 0) missing_glyph else g +% delta;
    }

    fn cmap12(f: *const Font, cp: u21) Error!u16 {
        const t = f.cmap;
        const n = try read(u32, t, 12);
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = 16 + mid * 12;
            const start = try read(u32, t, rec);
            const end = try read(u32, t, rec + 4);
            if (cp < start) {
                hi = mid;
            } else if (cp > end) {
                lo = mid + 1;
            } else {
                return @truncate(try read(u32, t, rec + 8) + (cp - start));
            }
        }
        return missing_glyph;
    }

    /// Advance width in font units.
    pub fn advance(f: *const Font, glyph: u16) u16 {
        const i = @min(glyph, f.num_hmetrics - 1);
        return read(u16, f.hmtx, @as(usize, i) * 4) catch 0;
    }

    /// Left side bearing in font units.
    pub fn leftSideBearing(f: *const Font, glyph: u16) i16 {
        if (glyph < f.num_hmetrics) return read(i16, f.hmtx, @as(usize, glyph) * 4 + 2) catch 0;
        const at = @as(usize, f.num_hmetrics) * 4 + (@as(usize, glyph) - f.num_hmetrics) * 2;
        return read(i16, f.hmtx, at) catch 0;
    }

    /// The glyph's data in `glyf`; empty for glyphs with no outline (such as
    /// the space).
    fn glyphData(f: *const Font, glyph: u16) Error![]const u8 {
        if (glyph >= f.num_glyphs) return error.Malformed;
        const start: usize, const end: usize = if (f.long_loca)
            .{ try read(u32, f.loca, @as(usize, glyph) * 4), try read(u32, f.loca, @as(usize, glyph) * 4 + 4) }
        else
            .{ @as(usize, try read(u16, f.loca, @as(usize, glyph) * 2)) * 2, @as(usize, try read(u16, f.loca, @as(usize, glyph) * 2 + 2)) * 2 };
        if (end < start) return error.Malformed;
        return sub(f.glyf, start, end - start);
    }

    /// The glyph's bounding box, or null if it has no outline.
    pub fn boundingBox(f: *const Font, glyph: u16) ?Box {
        const g = f.glyphData(glyph) catch return null;
        if (g.len < 10) return null;
        return .{
            .x_min = read(i16, g, 2) catch return null,
            .y_min = read(i16, g, 4) catch return null,
            .x_max = read(i16, g, 6) catch return null,
            .y_max = read(i16, g, 8) catch return null,
        };
    }

    /// Emits the glyph's outline, transformed by `t`, to `sink`, which has
    /// `moveTo(x, y)`, `lineTo(x, y)` and `quadTo(cx, cy, x, y)` methods.
    /// Each contour starts with moveTo and ends back at its start.
    pub fn outline(f: *const Font, glyph: u16, t: Transform, sink: anytype) Error!void {
        return f.outlineDepth(glyph, t, sink, 0);
    }

    fn outlineDepth(f: *const Font, glyph: u16, t: Transform, sink: anytype, depth: u8) Error!void {
        if (depth > 8) return error.Malformed;
        const g = try f.glyphData(glyph);
        if (g.len == 0) return;
        const contours = try read(i16, g, 0);
        if (contours >= 0) return simpleOutline(g, @intCast(contours), t, sink);

        // Composite: other glyphs, each with its own offset and transform.
        const ARG_1_AND_2_ARE_WORDS = 0x0001;
        const ARGS_ARE_XY_VALUES = 0x0002;
        const WE_HAVE_A_SCALE = 0x0008;
        const MORE_COMPONENTS = 0x0020;
        const WE_HAVE_AN_X_AND_Y_SCALE = 0x0040;
        const WE_HAVE_A_TWO_BY_TWO = 0x0080;
        var at: usize = 10;
        while (true) {
            const flags = try read(u16, g, at);
            const component = try read(u16, g, at + 2);
            at += 4;
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (flags & ARG_1_AND_2_ARE_WORDS != 0) {
                dx = @floatFromInt(try read(i16, g, at));
                dy = @floatFromInt(try read(i16, g, at + 2));
                at += 4;
            } else {
                dx = @floatFromInt(try read(i8, g, at));
                dy = @floatFromInt(try read(i8, g, at + 1));
                at += 2;
            }
            // Point-matched placement is rare; treat it as no offset.
            if (flags & ARGS_ARE_XY_VALUES == 0) {
                dx = 0;
                dy = 0;
            }
            var m: Transform = .{ .e = dx, .f = dy };
            const f2dot14 = struct {
                fn v(data: []const u8, o: usize) Error!f32 {
                    return @as(f32, @floatFromInt(try read(i16, data, o))) / 16384.0;
                }
            }.v;
            if (flags & WE_HAVE_A_SCALE != 0) {
                m.a = try f2dot14(g, at);
                m.d = m.a;
                at += 2;
            } else if (flags & WE_HAVE_AN_X_AND_Y_SCALE != 0) {
                m.a = try f2dot14(g, at);
                m.d = try f2dot14(g, at + 2);
                at += 4;
            } else if (flags & WE_HAVE_A_TWO_BY_TWO != 0) {
                m.a = try f2dot14(g, at);
                m.b = try f2dot14(g, at + 2);
                m.c = try f2dot14(g, at + 4);
                m.d = try f2dot14(g, at + 6);
                at += 8;
            }
            try f.outlineDepth(component, m.then(t), sink, depth + 1);
            if (flags & MORE_COMPONENTS == 0) break;
        }
    }

    // --- Kerning ------------------------------------------------------------

    fn findKernLookups(f: *Font, gpos: []const u8) Error!void {
        f.gpos = gpos;
        const feature_list = try read(u16, gpos, 6);
        const n = try read(u16, gpos, feature_list);
        for (0..n) |i| {
            const rec = feature_list + 2 + i * 6;
            if (try read(u32, gpos, rec) != tag("kern")) continue;
            const feature = feature_list + @as(usize, try read(u16, gpos, rec + 4));
            const count = try read(u16, gpos, feature + 2);
            for (0..count) |j| {
                const lookup = try read(u16, gpos, feature + 4 + j * 2);
                const known = std.mem.indexOfScalar(u16, f.kern_lookups[0..f.num_kern_lookups], lookup) != null;
                if (known or f.num_kern_lookups == max_kern_lookups) continue;
                f.kern_lookups[f.num_kern_lookups] = lookup;
                f.num_kern_lookups += 1;
            }
        }
    }

    /// Horizontal kerning between two glyphs, in font units (usually
    /// negative, to pull them together).
    pub fn kerning(f: *const Font, left: u16, right: u16) i16 {
        var total: i32 = 0;
        for (f.kern_lookups[0..f.num_kern_lookups]) |lookup| {
            total += f.lookupKerning(lookup, left, right) catch 0;
        }
        return @intCast(std.math.clamp(total, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    fn lookupKerning(f: *const Font, lookup_index: u16, left: u16, right: u16) Error!i16 {
        const g = f.gpos;
        const lookup_list = try read(u16, g, 8);
        const lookup = lookup_list + @as(usize, try read(u16, g, lookup_list + 2 + @as(usize, lookup_index) * 2));
        const lookup_type = try read(u16, g, lookup);
        const count = try read(u16, g, lookup + 4);
        for (0..count) |i| {
            var st = lookup + @as(usize, try read(u16, g, lookup + 6 + i * 2));
            var subtable_type = lookup_type;
            if (lookup_type == 9) {
                // Extension: the real subtable is at a 32-bit offset.
                subtable_type = try read(u16, g, st + 2);
                st += try read(u32, g, st + 4);
            }
            if (subtable_type != 2) continue;
            if (try pairAdjustment(g, st, left, right)) |v| return v;
        }
        return 0;
    }

    // --- Colour glyphs and ligatures ----------------------------------------

    /// The back-to-front colour layers of `glyph` from the `COLR` v0 and
    /// `CPAL` tables, or null if `glyph` is not a layered colour glyph.
    pub fn colorLayers(f: *const Font, glyph: u16) ?ColorLayers {
        if (f.colr.len < 14 or f.cpal.len < 14) return null;
        return f.findColorLayers(glyph) catch null;
    }

    fn findColorLayers(f: *const Font, glyph: u16) Error!?ColorLayers {
        const colr = f.colr;
        const num_base = try read(u16, colr, 2);
        const base_off = try read(u32, colr, 4);
        var lo: usize = 0;
        var hi: usize = num_base;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = @as(usize, base_off) + mid * 6;
            const g = try read(u16, colr, rec);
            if (g == glyph) {
                const first = try read(u16, colr, rec + 2);
                const count = try read(u16, colr, rec + 4);
                if (count == 0) return null;
                return .{ .font = f, .first = first, .count = count };
            }
            if (g < glyph) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn colorLayer(f: *const Font, index: usize) Error!ColorLayer {
        const colr = f.colr;
        const layer_off = try read(u32, colr, 8);
        const num_layers = try read(u16, colr, 12);
        if (index >= num_layers) return error.Malformed;
        const rec = @as(usize, layer_off) + index * 4;
        const glyph = try read(u16, colr, rec);
        if (glyph >= f.num_glyphs) return error.Malformed;
        const palette_index = try read(u16, colr, rec + 2);
        if (palette_index == 0xffff) return .{ .glyph = glyph, .color = null };
        const cpal = f.cpal;
        const num_entries = try read(u16, cpal, 2);
        const num_palettes = try read(u16, cpal, 4);
        const num_records = try read(u16, cpal, 6);
        const records_off = try read(u32, cpal, 8);
        if (num_palettes == 0 or palette_index >= num_entries) return error.Malformed;
        const first_color = try read(u16, cpal, 12);
        const color_index = @as(usize, first_color) + palette_index;
        if (color_index >= num_records) return error.Malformed;
        const crec = @as(usize, records_off) + color_index * 4;
        const b: u32 = try read(u8, cpal, crec);
        const g: u32 = try read(u8, cpal, crec + 1);
        const r: u32 = try read(u8, cpal, crec + 2);
        const a: u32 = try read(u8, cpal, crec + 3);
        return .{ .glyph = glyph, .color = (a << 24) | (r << 16) | (g << 8) | b };
    }

    fn findCcmpLookups(f: *Font, gsub: []const u8) Error!void {
        f.gsub = gsub;
        const feature_list = try read(u16, gsub, 6);
        const lookup_list = try read(u16, gsub, 8);
        const n = try read(u16, gsub, feature_list);
        for (0..n) |i| {
            const rec = feature_list + 2 + i * 6;
            if (try read(u32, gsub, rec) != tag("ccmp")) continue;
            const feature = feature_list + @as(usize, try read(u16, gsub, rec + 4));
            const count = try read(u16, gsub, feature + 2);
            for (0..count) |j| {
                const lookup_idx = try read(u16, gsub, feature + 4 + j * 2);
                const lookup = lookup_list + @as(usize, try read(u16, gsub, lookup_list + 2 + @as(usize, lookup_idx) * 2));
                const lookup_type = try read(u16, gsub, lookup);
                if (lookup_type != 4 and lookup_type != 7) continue;
                const known = std.mem.indexOfScalar(u16, f.ccmp_lookups[0..f.num_ccmp_lookups], lookup_idx) != null;
                if (known or f.num_ccmp_lookups == max_kern_lookups) continue;
                f.ccmp_lookups[f.num_ccmp_lookups] = lookup_idx;
                f.num_ccmp_lookups += 1;
            }
        }
    }

    /// Ligature substitution from the `GSUB` `ccmp` feature (used by emoji
    /// fonts for flags, skin tones, keycaps, and ZWJ sequences), or null if no
    /// ligature starts with `first` followed by a prefix of `rest`.
    pub fn ligature(f: *const Font, first: u16, rest: []const u16) ?Ligature {
        if (rest.len == 0 or f.num_ccmp_lookups == 0) return null;
        for (f.ccmp_lookups[0..f.num_ccmp_lookups]) |lookup| {
            if (f.lookupLigature(lookup, first, rest) catch null) |lig| return lig;
        }
        return null;
    }

    fn lookupLigature(f: *const Font, lookup_index: u16, first: u16, rest: []const u16) Error!?Ligature {
        const g = f.gsub;
        const lookup_list = try read(u16, g, 8);
        const lookup = lookup_list + @as(usize, try read(u16, g, lookup_list + 2 + @as(usize, lookup_index) * 2));
        const lookup_type = try read(u16, g, lookup);
        const count = try read(u16, g, lookup + 4);
        for (0..count) |i| {
            var st = lookup + @as(usize, try read(u16, g, lookup + 6 + i * 2));
            var subtable_type = lookup_type;
            if (lookup_type == 7) {
                subtable_type = try read(u16, g, st + 2);
                st += try read(u32, g, st + 4);
            }
            if (subtable_type != 4) continue;
            if (try ligatureSubst(g, st, first, rest)) |lig| {
                if (lig.glyph < f.num_glyphs) return lig;
            }
        }
        return null;
    }
};

/// Reads a TrueType simple glyph and emits its contours.
fn simpleOutline(g: []const u8, contours: usize, t: Transform, sink: anytype) Error!void {
    if (contours == 0) return;
    const max_points = 2048;
    var end_points: [256]u16 = undefined;
    if (contours > end_points.len) return error.Unsupported;
    for (0..contours) |i| end_points[i] = try read(u16, g, 10 + i * 2);
    const num_points = @as(usize, end_points[contours - 1]) + 1;
    if (num_points > max_points) return error.Unsupported;
    const instructions = try read(u16, g, 10 + contours * 2);
    var at = 12 + contours * 2 + @as(usize, instructions);

    const ON_CURVE = 0x01;
    const X_SHORT = 0x02;
    const Y_SHORT = 0x04;
    const REPEAT = 0x08;
    const X_SAME_OR_POSITIVE = 0x10;
    const Y_SAME_OR_POSITIVE = 0x20;
    var flags: [max_points]u8 = undefined;
    var i: usize = 0;
    while (i < num_points) {
        const flag = try read(u8, g, at);
        at += 1;
        var repeat: usize = 1;
        if (flag & REPEAT != 0) {
            repeat += try read(u8, g, at);
            at += 1;
        }
        if (i + repeat > num_points) return error.Malformed;
        @memset(flags[i..][0..repeat], flag);
        i += repeat;
    }
    var points: [max_points][2]f32 = undefined;
    inline for (.{ 0, 1 }) |axis| {
        const short = if (axis == 0) X_SHORT else Y_SHORT;
        const same = if (axis == 0) X_SAME_OR_POSITIVE else Y_SAME_OR_POSITIVE;
        var v: i32 = 0;
        for (flags[0..num_points], 0..) |flag, p| {
            if (flag & short != 0) {
                const d: i32 = try read(u8, g, at);
                at += 1;
                v += if (flag & same != 0) d else -d;
            } else if (flag & same == 0) {
                v += try read(i16, g, at);
                at += 2;
            }
            points[p][axis] = @floatFromInt(v);
        }
    }

    var start: usize = 0;
    for (end_points[0..contours]) |end_point| {
        const end = @as(usize, end_point) + 1;
        if (end <= start or end > num_points) return error.Malformed;
        try emitContour(points[start..end], flags[start..end], ON_CURVE, t, sink);
        start = end;
    }
}

/// Emits one closed contour of on- and off-curve points. Two consecutive
/// off-curve points imply an on-curve point midway between them.
fn emitContour(pts: []const [2]f32, flags: []const u8, on_curve: u8, t: Transform, sink: anytype) Error!void {
    const n = pts.len;
    const mid = struct {
        fn f(a: [2]f32, b: [2]f32) [2]f32 {
            return .{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2 };
        }
    }.f;
    const on = struct {
        fn f(fl: []const u8, i: usize, bit: u8) bool {
            return fl[i] & bit != 0;
        }
    }.f;
    // Start at an on-curve point: the first, else the last, else the
    // midpoint between them.
    var start: [2]f32 = undefined;
    var first: usize = 0; // first point after the start, as an index into pts
    var count: usize = n; // points after the start, including back to it
    if (on(flags, 0, on_curve)) {
        start = pts[0];
        first = 1;
        count = n - 1;
    } else if (on(flags, n - 1, on_curve)) {
        start = pts[n - 1];
        first = 0;
        count = n - 1;
    } else {
        start = mid(pts[n - 1], pts[0]);
    }
    const s = t.apply(start[0], start[1]);
    sink.moveTo(s[0], s[1]);
    var ctrl: ?[2]f32 = null;
    for (0..count) |k| {
        const idx = (first + k) % n;
        const p = pts[idx];
        if (on(flags, idx, on_curve)) {
            const q = t.apply(p[0], p[1]);
            if (ctrl) |c| {
                const cc = t.apply(c[0], c[1]);
                sink.quadTo(cc[0], cc[1], q[0], q[1]);
            } else sink.lineTo(q[0], q[1]);
            ctrl = null;
        } else {
            if (ctrl) |c| {
                const m = mid(c, p);
                const cc = t.apply(c[0], c[1]);
                const mm = t.apply(m[0], m[1]);
                sink.quadTo(cc[0], cc[1], mm[0], mm[1]);
            }
            ctrl = p;
        }
    }
    if (ctrl) |c| {
        const cc = t.apply(c[0], c[1]);
        sink.quadTo(cc[0], cc[1], s[0], s[1]);
    } else sink.lineTo(s[0], s[1]);
}

// --- GPOS pair adjustment -----------------------------------------------------

/// Index of `glyph` in a coverage table, if covered.
fn coverageIndex(g: []const u8, table: usize, glyph: u16) Error!?usize {
    const format = try read(u16, g, table);
    const count = try read(u16, g, table + 2);
    var lo: usize = 0;
    var hi: usize = count;
    if (format == 1) {
        while (lo < hi) {
            const m = (lo + hi) / 2;
            const v = try read(u16, g, table + 4 + m * 2);
            if (v == glyph) return m;
            if (v < glyph) lo = m + 1 else hi = m;
        }
        return null;
    }
    if (format != 2) return error.Malformed;
    while (lo < hi) {
        const m = (lo + hi) / 2;
        const rec = table + 4 + m * 6;
        const start = try read(u16, g, rec);
        const end = try read(u16, g, rec + 2);
        if (glyph < start) {
            hi = m;
        } else if (glyph > end) {
            lo = m + 1;
        } else return @as(usize, try read(u16, g, rec + 4)) + (glyph - start);
    }
    return null;
}

/// The class of `glyph` in a class definition table (0 if not listed).
fn classOf(g: []const u8, table: usize, glyph: u16) Error!u16 {
    const format = try read(u16, g, table);
    if (format == 1) {
        const start = try read(u16, g, table + 2);
        const count = try read(u16, g, table + 4);
        if (glyph < start or glyph - start >= count) return 0;
        return read(u16, g, table + 6 + @as(usize, glyph - start) * 2);
    }
    if (format != 2) return error.Malformed;
    const count = try read(u16, g, table + 2);
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const m = (lo + hi) / 2;
        const rec = table + 4 + m * 6;
        const start = try read(u16, g, rec);
        const end = try read(u16, g, rec + 2);
        if (glyph < start) {
            hi = m;
        } else if (glyph > end) {
            lo = m + 1;
        } else return read(u16, g, rec + 4);
    }
    return 0;
}

fn valueRecordSize(format: u16) usize {
    return @as(usize, @popCount(format)) * 2;
}

/// The XAdvance field of a value record, if present.
fn xAdvance(g: []const u8, record: usize, format: u16) Error!i16 {
    if (format & 0x0004 == 0) return 0;
    // XPlacement and YPlacement come first when present.
    return read(i16, g, record + @as(usize, @popCount(format & 0x0003)) * 2);
}

/// A pair adjustment subtable's kerning for (left, right), or null if the
/// subtable does not cover the pair.
fn pairAdjustment(g: []const u8, st: usize, left: u16, right: u16) Error!?i16 {
    const format = try read(u16, g, st);
    const coverage = st + @as(usize, try read(u16, g, st + 2));
    const vf1 = try read(u16, g, st + 4);
    const vf2 = try read(u16, g, st + 6);
    const index = try coverageIndex(g, coverage, left) orelse return null;
    const record_size = 2 + valueRecordSize(vf1) + valueRecordSize(vf2);
    if (format == 1) {
        const set = st + @as(usize, try read(u16, g, st + 10 + index * 2));
        const count = try read(u16, g, set);
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const m = (lo + hi) / 2;
            const rec = set + 2 + m * record_size;
            const second = try read(u16, g, rec);
            if (second == right) return try xAdvance(g, rec + 2, vf1);
            if (second < right) lo = m + 1 else hi = m;
        }
        return null;
    }
    if (format != 2) return null;
    const class_def1 = st + @as(usize, try read(u16, g, st + 8));
    const class_def2 = st + @as(usize, try read(u16, g, st + 10));
    const class1_count = try read(u16, g, st + 12);
    const class2_count = try read(u16, g, st + 14);
    const c1 = try classOf(g, class_def1, left);
    const c2 = try classOf(g, class_def2, right);
    if (c1 >= class1_count or c2 >= class2_count) return null;
    const size = valueRecordSize(vf1) + valueRecordSize(vf2);
    const rec = st + 16 + (@as(usize, c1) * class2_count + c2) * size;
    return try xAdvance(g, rec, vf1);
}

fn ligatureSubst(g: []const u8, st: usize, first: u16, rest: []const u16) Error!?Font.Ligature {
    const format = try read(u16, g, st);
    if (format != 1) return null;
    const coverage = st + @as(usize, try read(u16, g, st + 2));
    const set_count = try read(u16, g, st + 4);
    const index = try coverageIndex(g, coverage, first) orelse return null;
    if (index >= set_count) return error.Malformed;
    const set = st + @as(usize, try read(u16, g, st + 6 + index * 2));
    const lig_count = try read(u16, g, set);
    next_lig: for (0..lig_count) |i| {
        const lig = set + @as(usize, try read(u16, g, set + 2 + i * 2));
        const lig_glyph = try read(u16, g, lig);
        const comp_count = try read(u16, g, lig + 2);
        if (comp_count < 2 or comp_count - 1 > rest.len) continue;
        for (0..comp_count - 1) |k| {
            if (try read(u16, g, lig + 4 + k * 2) != rest[k]) continue :next_lig;
        }
        return .{ .glyph = lig_glyph, .consumed = comp_count - 1 };
    }
    return null;
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const fira = @embedFile("../fonts/FiraSans-Regular.ttf");

/// Records outline commands for tests.
const Recorder = struct {
    moves: usize = 0,
    lines: usize = 0,
    quads: usize = 0,
    min: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) },
    max: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) },

    fn see(r: *Recorder, x: f32, y: f32) void {
        r.min = .{ @min(r.min[0], x), @min(r.min[1], y) };
        r.max = .{ @max(r.max[0], x), @max(r.max[1], y) };
    }
    pub fn moveTo(r: *Recorder, x: f32, y: f32) void {
        r.moves += 1;
        r.see(x, y);
    }
    pub fn lineTo(r: *Recorder, x: f32, y: f32) void {
        r.lines += 1;
        r.see(x, y);
    }
    pub fn quadTo(r: *Recorder, cx: f32, cy: f32, x: f32, y: f32) void {
        r.quads += 1;
        r.see(cx, cy);
        r.see(x, y);
    }
};

test "Fira Sans tables" {
    const f = try Font.init(fira);
    try testing.expectEqual(@as(u16, 1000), f.units_per_em);
    try testing.expect(f.ascender > 700 and f.descender < -200);
    try testing.expect(f.num_kern_lookups > 0);
    const a = f.glyphIndex('A');
    try testing.expect(a != missing_glyph);
    try testing.expect(f.glyphIndex(0x10ffff) == missing_glyph);
    // Greek and Cyrillic are covered.
    try testing.expect(f.glyphIndex(0x03a9) != missing_glyph); // Ω
    try testing.expect(f.glyphIndex(0x0416) != missing_glyph); // Ж
    try testing.expect(f.advance(a) > 400 and f.advance(a) < 800);
}

test "outlines stay within the bounding box" {
    const f = try Font.init(fira);
    for ("AgQ&8%@") |ch| {
        const g = f.glyphIndex(ch);
        var r: Recorder = .{};
        try f.outline(g, .{}, &r);
        try testing.expect(r.moves >= 1);
        try testing.expect(r.lines + r.quads > 4);
        const box = f.boundingBox(g).?;
        // Control points of a TrueType outline lie within the box.
        try testing.expect(r.min[0] >= @as(f32, @floatFromInt(box.x_min)) - 0.5);
        try testing.expect(r.max[1] <= @as(f32, @floatFromInt(box.y_max)) + 0.5);
    }
    // The space has no outline.
    var r: Recorder = .{};
    try f.outline(f.glyphIndex(' '), .{}, &r);
    try testing.expectEqual(@as(usize, 0), r.moves);
}

test "composite glyphs draw their components" {
    const f = try Font.init(fira);
    // Accented letters are usually composites of a base and an accent.
    var r: Recorder = .{};
    try f.outline(f.glyphIndex(0x00c5), .{}, &r); // Å
    try testing.expect(r.moves >= 2);
    const a_box = f.boundingBox(f.glyphIndex('A')).?;
    try testing.expect(r.max[1] > @as(f32, @floatFromInt(a_box.y_max)) + 50);
}

test "kerning matches fontTools" {
    const f = try Font.init(fira);
    // Expected values from fontTools' reading of the same GPOS table. Both
    // formats occur: class-based pairs (format 2) and specific pairs
    // (format 1).
    const pairs = [_]struct { []const u8, i16 }{
        .{ "AV", -14 }, .{ "To", -55 }, .{ "Ty", -40 }, .{ "LT", -83 },  .{ "Yo", -59 },
        .{ "Wa", -30 }, .{ "HH", 0 },   .{ "r.", -80 }, .{ "P,", -120 },
    };
    for (pairs) |p| {
        try testing.expectEqual(p[1], f.kerning(f.glyphIndex(p[0][0]), f.glyphIndex(p[0][1])));
    }
}

test "malformed data is rejected" {
    try testing.expectError(error.Malformed, Font.init("not a font"));
    try testing.expectError(error.Malformed, Font.init(fira[0..200]));
}

test "transforms compose" {
    const inner: Transform = .{ .a = 2, .d = 2, .e = 1 };
    const outer: Transform = .{ .d = -1, .f = 10 };
    const p = inner.then(outer).apply(3, 4);
    try testing.expectEqual([2]f32{ 7, 2 }, p);
}

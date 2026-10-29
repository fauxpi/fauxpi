//! Font renderer: OpenType fonts with TrueType outlines,
//! rasterized with exact-area anti-aliasing and laid out with kerning.
//!
//! * `opentype`: parsing the font (character map, metrics, outlines, GPOS
//!   kerning)
//! * `raster`: rasterizing outlines into coverage masks
//! * `text`: the glyph cache, layout, and drawing into 32-bit pixels

pub const opentype = @import("opentype.zig");
pub const raster = @import("raster.zig");
pub const text = @import("text.zig");

pub const Font = opentype.Font;
pub const Canvas = text.Canvas;
pub const GlyphCache = text.GlyphCache;
pub const Style = text.Style;
pub const Layout = text.Layout;
pub const Run = text.Run;
pub const RunCache = text.RunCache;
pub const Bitmap = text.Bitmap;
pub const rasterizeGlyph = text.rasterizeGlyph;
pub const draw = text.draw;
pub const measure = text.measure;

test {
    _ = opentype;
    _ = raster;
    _ = text;
}

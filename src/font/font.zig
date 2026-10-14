//! Dazzle's font renderer: OpenType fonts with TrueType outlines,
//! rasterized with exact-area anti-aliasing and laid out with kerning.
//!
//! * `opentype`: parsing the font (character map, metrics, outlines, GPOS
//!   kerning)
//! * `raster`: rasterizing outlines into coverage masks
//! * `text`: the glyph cache, layout, and drawing into 32-bit pixels
//!
//! Dazzle's apps use Fira Sans (SIL Open Font License); each app carries
//! its own copy, next to its executable.
//!
//!     const f = try font.Font.init(data);
//!     var cache = font.GlyphCache.init(gpa);
//!     _ = try font.draw(canvas, &cache, .{ .font = &f, .size = 32 }, x, baseline, "Hello");

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

/// The file name Fira Sans is under (in /os/fonts, see `sys.fontFile`).
pub const default_font_file = "FiraSans-Regular.ttf";

/// The system colour emoji font in /os/fonts.
pub const emoji_font_file = "TwemojiMozilla.ttf";

test {
    _ = opentype;
    _ = raster;
    _ = text;
}

// Single translation unit that instantiates the stb_truetype implementation.
// stb_truetype.h is a public-domain single-header library (v1.26); defining
// STB_TRUETYPE_IMPLEMENTATION in exactly ONE .c file emits the code. We compile
// this TU through Zig's bundled clang (`addCSourceFile` in build.zig) so there
// is no system C-library dependency for glyph rasterisation.
//
// We route stb's libc needs (malloc/free, math) through the definitions Zig
// links against, so the only external symbol this TU needs is standard libc,
// which Zig's `link_libc` provides.
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

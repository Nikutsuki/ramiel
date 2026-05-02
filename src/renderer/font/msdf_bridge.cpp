#include <ft2build.h>
#include FT_FREETYPE_H

#include <msdfgen.h>
#include <msdfgen-ext.h>

#include <cstdint>

extern "C" int msdfgen_generate_glyph_rgba(
    FT_Face ft_face,
    unsigned glyph_index,
    int width,
    int height,
    double bearing_x,
    double bearing_y,
    double px_range,
    double shape_scale,
    unsigned char *out_rgba
) {
    if (!ft_face || !out_rgba || glyph_index == 0 || width <= 0 || height <= 0) return 0;

    msdfgen::FontHandle *font = msdfgen::adoptFreetypeFont(ft_face);
    if (!font) return 0;

    msdfgen::Shape shape;
    const bool loaded = msdfgen::loadGlyph(
        shape,
        font,
        msdfgen::GlyphIndex(glyph_index),
        msdfgen::FONT_SCALING_NONE,
        nullptr
    );
    msdfgen::destroyFont(font);

    if (!loaded || shape.contours.empty()) return 0;

    shape.normalize();
    msdfgen::edgeColoringSimple(shape, 3.0);

    const msdfgen::Projection projection(
        msdfgen::Vector2(shape_scale, -shape_scale),
        msdfgen::Vector2(-bearing_x / shape_scale, -bearing_y / shape_scale)
    );
    const msdfgen::SDFTransformation transform(projection, msdfgen::Range(px_range / shape_scale));

    msdfgen::Bitmap<float, 3> msdf(width, height, msdfgen::Y_DOWNWARD);
    msdfgen::generateMSDF(msdf, shape, transform);
    msdfgen::simulate8bit(msdf);

    for (int row = 0; row < height; row++) {
        const int src_row = height - 1 - row;
        for (int col = 0; col < width; col++) {
            const float *px = msdf(col, src_row);
            const unsigned char r = msdfgen::pixelFloatToByte(px[0]);
            const unsigned char g = msdfgen::pixelFloatToByte(px[1]);
            const unsigned char b = msdfgen::pixelFloatToByte(px[2]);
            const int dst = (row * width + col) * 4;

            out_rgba[dst + 0] = r;
            out_rgba[dst + 1] = g;
            out_rgba[dst + 2] = b;
            out_rgba[dst + 3] = 255;
        }
    }

    return 1;
}

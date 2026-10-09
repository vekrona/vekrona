#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 tint;
    float opaqueIconAlpha;
    float opaqueContrastGain;
    float bodyContrastGain;
};

layout(binding = 1) uniform sampler2D source;

float luminance(vec3 rgb) {
    return dot(rgb, vec3(0.2126, 0.7152, 0.0722));
}

const int GRID = 8;
const int BINS = 8;

vec3 unpremultiplied(vec4 px) {
    return px.a > 0.0 ? px.rgb / px.a : vec3(0.0);
}

// The luminance of the icon's body: the mean of the most common luminance bin among the opaque samples of a coarse grid.
// Returns false when no sample is opaque, so the icon has no body.
bool bodyLuminance(ivec2 size, out float reference) {
    float sums[BINS];
    int counts[BINS];
    for (int b = 0; b < BINS; b++) {
        sums[b] = 0.0;
        counts[b] = 0;
    }
    for (int j = 0; j < GRID; j++) {
        for (int i = 0; i < GRID; i++) {
            vec4 px = texelFetch(source, ivec2((vec2(i, j) + 0.5) / float(GRID) * vec2(size)), 0);
            if (px.a >= opaqueIconAlpha) {
                float lum = luminance(unpremultiplied(px));
                int bin = min(int(lum * float(BINS)), BINS - 1);
                sums[bin] += lum;
                counts[bin]++;
            }
        }
    }
    int mode = 0;
    for (int b = 1; b < BINS; b++) {
        if (counts[b] > counts[mode])
            mode = b;
    }
    reference = sums[mode] / float(max(counts[mode], 1));
    return counts[mode] > 0;
}

void main() {
    ivec2 size = textureSize(source, 0);
    ivec2 last = size - 1;
    vec4 corner0 = texelFetch(source, ivec2(0, 0), 0);
    vec4 corners[3] = vec4[](
        texelFetch(source, ivec2(last.x, 0), 0),
        texelFetch(source, ivec2(0, last.y), 0),
        texelFetch(source, last, 0)
    );
    bool opaque = corner0.a >= opaqueIconAlpha;
    for (int i = 0; i < 3; i++)
        opaque = opaque && corners[i].a >= opaqueIconAlpha;

    vec4 px = texture(source, qt_TexCoord0);
    float mask = px.a;
    float body;
    if (opaque)
        mask = min(1.0, opaqueContrastGain * abs(luminance(px.rgb) - luminance(corner0.rgb)));
    else if (bodyLuminance(size, body))
        mask *= 1.0 - min(1.0, bodyContrastGain * abs(luminance(unpremultiplied(px)) - body));
    fragColor = vec4(tint.rgb, 1.0) * mask * qt_Opacity;
}

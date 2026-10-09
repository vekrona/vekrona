import QtQuick
import "Vekrona"

Canvas {
    id: root

    required property url source
    required property color tint
    property int size: VekronaTheme.iconS
    // Some tray icons (Tailscale's) ship an opaque square. A corner alpha of at least opaqueIconAlpha marks one, and
    // opaqueContrastGain scales its glyph's contrast to the corner colour into the mask.
    readonly property real opaqueIconAlpha: 0.98
    readonly property real opaqueContrastGain: 2

    function luminance(px: var, i: int): real {
        return (0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2]) / 255;
    }

    function cornerOffsets(w: int, h: int): var {
        return [0, 4 * (w - 1), 4 * w * (h - 1), 4 * (w * h - 1)];
    }

    function maskOf(px: var, w: int, h: int): var {
        const corners = cornerOffsets(w, h);
        const opaque = corners.every(c => px[c + 3] >= opaqueIconAlpha * 255);
        const background = luminance(px, corners[0]);
        const mask = new Array(w * h);
        for (let p = 0; p < w * h; p++) {
            mask[p] = opaque ? Math.min(1, opaqueContrastGain * Math.abs(luminance(px, 4 * p) - background)) : px[4 * p + 3] / 255;
        }
        return mask;
    }

    // Qt Canvas draws in item units but getImageData reads window pixels (Screen.devicePixelRatio rounds a 1.5 scale up to 2, so use
    // the window's), and its putImageData paints nothing, so the mask is drawn back as an image. Without smooth:false a texel
    // that misses a screen pixel is blurred.
    smooth: false
    width: size
    height: size
    onSourceChanged: loadImage(source)
    onTintChanged: requestPaint()
    onImageLoaded: requestPaint()
    Component.onCompleted: loadImage(source)

    onPaint: {
        if (!isImageLoaded(source))
            return;
        const ctx = getContext("2d");
        const px = Math.round(size * Window.window.devicePixelRatio);
        ctx.clearRect(0, 0, size, size);
        ctx.drawImage(source, 0, 0, size, size);
        const mask = maskOf(ctx.getImageData(0, 0, px, px).data, px, px);
        const tinted = ctx.createImageData(px, px);
        for (let p = 0; p < px * px; p++) {
            tinted.data[4 * p] = Math.round(tint.r * 255);
            tinted.data[4 * p + 1] = Math.round(tint.g * 255);
            tinted.data[4 * p + 2] = Math.round(tint.b * 255);
            tinted.data[4 * p + 3] = Math.round(mask[p] * 255);
        }
        ctx.clearRect(0, 0, size, size);
        ctx.drawImage(tinted, 0, 0, size, size);
    }
}

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

    width: size
    height: size
    canvasSize: Qt.size(size * Screen.devicePixelRatio, size * Screen.devicePixelRatio)
    onSourceChanged: loadImage(source)
    onTintChanged: requestPaint()
    onImageLoaded: requestPaint()
    Component.onCompleted: loadImage(source)

    onPaint: {
        if (!isImageLoaded(source))
            return;
        const ctx = getContext("2d");
        const w = Math.round(canvasSize.width);
        const h = Math.round(canvasSize.height);
        ctx.clearRect(0, 0, w, h);
        ctx.drawImage(source, 0, 0, w, h);
        const mask = maskOf(ctx.getImageData(0, 0, w, h).data, w, h);
        ctx.clearRect(0, 0, w, h);
        for (let p = 0; p < w * h; p++) {
            ctx.fillStyle = Qt.rgba(tint.r, tint.g, tint.b, mask[p]);
            ctx.fillRect(p % w, Math.floor(p / w), 1, 1);
        }
    }
}

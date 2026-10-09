import QtQuick
import "Vekrona"

Item {
    id: root

    required property url source
    required property color tint
    property int size: VekronaTheme.iconS
    // Some tray icons (Tailscale's) ship an opaque square. A corner alpha of at least opaqueIconAlpha marks one, and
    // opaqueContrastGain scales its glyph's contrast to the corner colour into the mask.
    readonly property real opaqueIconAlpha: 0.98
    readonly property real opaqueContrastGain: 2
    // A non-opaque icon is tinted by its alpha, minus the opaque details that differ from its body (the most common opaque color).
    // A luminance difference of 0.5 leaves a quarter of the ink, a hole; a difference of 0.2, such as a shaded rim, keeps 70%; a flat
    // body or an anti-aliased edge, at about 0, stays whole.
    readonly property real bodyContrastGain: 1.5

    width: size
    height: size
    // The icon's position in the window, in logical pixels. It reads every ancestor's x and y, so it follows them. A box that
    // starts between two screen pixels is sampled half a pixel off, which skews the icon, so the shader effect moves to the pixel grid.
    readonly property point windowOffset: {
        let x = 0, y = 0;
        for (let item = root; item; item = item.parent) {
            x += item.x;
            y += item.y;
        }
        return Qt.point(x, y);
    }
    readonly property real dpr: Window.window ? Window.window.devicePixelRatio : 1

    // Loaded at the physical pixels of its logical size and smoothly scaled; the shader reads it and nothing paints it.
    Image {
        id: image
        source: root.source
        sourceSize: Qt.size(root.size, root.size)
        smooth: true
        visible: false
    }

    // tinted-icon.frag.qsb is baked from tinted-icon.frag by tests/bake-shaders.sh.
    ShaderEffect {
        function snapped(logical: real): real {
            return Math.round(logical * root.dpr) / root.dpr;
        }
        x: snapped(root.windowOffset.x) - root.windowOffset.x
        y: snapped(root.windowOffset.y) - root.windowOffset.y
        width: snapped(root.size)
        height: snapped(root.size)
        // The shader's sampler and uniforms, by name.
        property Image source: image
        property color tint: root.tint
        property real opaqueIconAlpha: root.opaqueIconAlpha
        property real opaqueContrastGain: root.opaqueContrastGain
        property real bodyContrastGain: root.bodyContrastGain
        fragmentShader: "tinted-icon.frag.qsb"
    }
}

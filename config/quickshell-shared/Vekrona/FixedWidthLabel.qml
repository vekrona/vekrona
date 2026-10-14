import QtQuick
import "."

// A right-aligned label with tabular figures that reserves the width of its widest text, so a changing value does
// not move its neighbours. A hidden Label measures the widest text because Text.implicitWidth is what the shown
// text lays out with; TextMetrics differs from it by about 1 px.
Item {
    id: root

    required property var style
    property string text
    // The widest text this label will show.
    property string widest
    property color color: VekronaTheme.c.ink
    property int elide: Text.ElideNone

    implicitWidth: Math.ceil(Math.max(shown.implicitWidth, measure.implicitWidth))
    implicitHeight: shown.implicitHeight

    Label {
        id: shown
        width: root.width
        elide: root.elide
        horizontalAlignment: Text.AlignRight
        font.features: { "tnum": 1 }
        style: root.style
        color: root.color
        text: root.text
    }

    Label {
        id: measure
        visible: false
        font.features: { "tnum": 1 }
        style: root.style
        text: root.widest
    }
}

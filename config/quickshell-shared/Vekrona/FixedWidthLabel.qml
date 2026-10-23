import QtQuick
import "."

// A label with tabular figures (right-aligned unless asked otherwise) that reserves the width of its widest text, so a
// changing value does not move its neighbours. Hidden Labels measure the widest texts because Text.implicitWidth is what
// the shown text lays out with; TextMetrics differs from it by about 1 px.
Item {
    id: root

    required property var style
    property string text
    // The texts this label may show, as one string or a list of strings: it reserves the width of the widest of them.
    property var widest: ""
    property color color: VekronaTheme.c.ink
    property int elide: Text.ElideNone
    property int alignment: Text.AlignRight

    implicitWidth: Math.ceil(Math.max(shown.implicitWidth, widestWidth()))
    implicitHeight: shown.implicitHeight

    function widestWidth(): real {
        let width = 0;
        for (let i = 0; i < measures.count; i++)
            width = Math.max(width, measures.itemAt(i).implicitWidth);
        return width;
    }

    Label {
        id: shown
        width: root.width
        elide: root.elide
        horizontalAlignment: root.alignment
        font.features: { "tnum": 1 }
        style: root.style
        color: root.color
        text: root.text
    }

    Repeater {
        id: measures
        model: Array.isArray(root.widest) ? root.widest : [root.widest]

        Label {
            required property string modelData

            visible: false
            font.features: { "tnum": 1 }
            style: root.style
            text: modelData
        }
    }
}

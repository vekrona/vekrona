import QtQuick
import "."

// The focused state of a control: two lines drawn inside the parent's bounds,
// `outer` on the edge and `inner` just inside it. A parent with its own border
// is covered by the outer line, so the ring replaces that border's color.
Rectangle {
    id: root

    required property bool shown
    property color outer: VekronaTheme.c.focus
    property color inner: VekronaTheme.c.focusInner

    visible: shown
    anchors.fill: parent
    color: "transparent"
    border.width: VekronaTheme.borderFocus
    border.color: outer

    Rectangle {
        anchors.fill: parent
        anchors.margins: VekronaTheme.borderFocus
        color: "transparent"
        border.width: VekronaTheme.borderFocus
        border.color: root.inner
    }
}

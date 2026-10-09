import QtQuick
import "."

Rectangle {
    required property bool shown

    visible: shown
    anchors.fill: parent
    anchors.margins: -(VekronaTheme.focusOffset + VekronaTheme.borderFocus)
    color: "transparent"
    border.width: VekronaTheme.borderFocus
    border.color: VekronaTheme.c.focus
}

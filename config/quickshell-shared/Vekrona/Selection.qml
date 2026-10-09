import QtQuick
import "."

// The background of the selected, current or active item. Place it right after
// the item's hover fill and before its content, so the selected fill wins over
// hover and sits beneath the text.
Rectangle {
    required property bool shown

    visible: shown
    anchors.fill: parent
    color: VekronaTheme.c.selected
}

import QtQuick
import "."

Rectangle {
    id: root

    // The dot hangs over the right padding of the pill (space2, as wide as the dot), so it never widens the pill.
    property int count: 0
    // Part way gone, while a Pulse of the count says so.
    property bool dimmed: false
    readonly property real dimOpacity: 0.3

    visible: count > 0
    opacity: dimmed ? dimOpacity : 1
    width: VekronaTheme.space2
    height: VekronaTheme.space2
    color: VekronaTheme.c.danger
    anchors.left: parent.right
    anchors.bottom: parent.verticalCenter
}

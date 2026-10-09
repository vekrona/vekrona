import QtQuick
import "."

Rectangle {
    id: root

    property int count: 0
    property bool dot: false
    readonly property real overhang: visible ? width - VekronaTheme.borderIndicator : 0

    visible: count > 0
    width: dot ? VekronaTheme.space2 : Math.max(height, text.implicitWidth + VekronaTheme.space1)
    height: dot ? VekronaTheme.space2 : VekronaTheme.space4
    color: VekronaTheme.c.danger
    anchors.left: parent.right
    anchors.leftMargin: -VekronaTheme.borderIndicator
    anchors.bottom: parent.verticalCenter

    Label {
        id: text
        visible: !root.dot
        anchors.centerIn: parent
        style: VekronaTheme.type.label
        text: root.count > 99 ? "99+" : String(root.count)
        color: VekronaTheme.c.onDanger
        font.features: ({ "tnum": 1 })
    }
}

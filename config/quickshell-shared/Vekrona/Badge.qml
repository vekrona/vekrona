import QtQuick
import "."

Rectangle {
    id: root

    property int count: 0
    readonly property real overhang: visible ? width : 0

    visible: count > 0
    width: Math.max(height, text.implicitWidth + VekronaTheme.space1)
    height: VekronaTheme.space4
    color: VekronaTheme.c.danger
    anchors.left: parent.right
    anchors.bottom: parent.verticalCenter

    Label {
        id: text
        anchors.centerIn: parent
        style: VekronaTheme.type.label
        text: root.count > 99 ? "99+" : String(root.count)
        color: VekronaTheme.c.onDanger
        font.features: ({ "tnum": 1 })
    }
}

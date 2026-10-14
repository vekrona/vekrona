import QtQuick
import "."

Rectangle {
    id: root

    // -1 has no badge. From 0 on, the badge reserves room for the widest one, so a count that appears or grows never moves its neighbours.
    property int count: -1
    readonly property real overhang: count >= 0 ? Math.max(height, Math.ceil(widest.implicitWidth) + VekronaTheme.space1) : 0

    visible: count > 0
    width: Math.max(height, Math.ceil(text.implicitWidth) + VekronaTheme.space1)
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

    Label {
        id: widest
        visible: false
        style: VekronaTheme.type.label
        text: "99+"
        font.features: ({ "tnum": 1 })
    }
}

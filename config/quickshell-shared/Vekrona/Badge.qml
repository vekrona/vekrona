import QtQuick
import "."

Rectangle {
    property int count: 0
    property bool dot: false

    visible: count > 0
    width: dot ? VekronaTheme.space2 : Math.max(height, text.implicitWidth + VekronaTheme.space1)
    height: dot ? VekronaTheme.space2 : VekronaTheme.iconS
    color: VekronaTheme.c.danger
    anchors.left: parent.right
    anchors.leftMargin: -VekronaTheme.space1
    anchors.top: parent.top
    anchors.topMargin: -VekronaTheme.space1

    Label {
        id: text
        visible: !parent.dot
        anchors.centerIn: parent
        style: VekronaTheme.type.label
        text: parent.count > 99 ? "99+" : String(parent.count)
        color: VekronaTheme.c.onDanger
        font.features: ({ "tnum": 1 })
    }
}

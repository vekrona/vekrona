import QtQuick
import "."

Item {
    id: root

    property string icon
    property string value
    property bool emphasized: false
    property bool filled: false
    property string ariaName
    property real overhang: 0
    // Keeps the value at least this wide, so a pill whose value changes does not shift its neighbours.
    property real valueMinWidth: 0
    // Reserves the icon's slot even with no icon, so rows that show a mark only on one of them stay aligned.
    property bool keepIconSlot: false
    // Muted text at the right edge, for rows wider than their content.
    property string trailing
    default property alias extra: iconBox.data

    signal clicked
    signal rightClicked
    signal wheel(int delta)

    implicitHeight: VekronaTheme.sizeTarget
    implicitWidth: 2 * VekronaTheme.space2 + content.width + (trailing !== "" ? VekronaTheme.space4 + trailingLabel.implicitWidth : 0) + overhang

    Accessible.role: Accessible.Button
    Accessible.name: ariaName
    activeFocusOnTab: true
    Keys.onReturnPressed: clicked()
    Keys.onSpacePressed: clicked()

    Rectangle {
        anchors.fill: parent
        color: mouse.pressed ? VekronaTheme.c.surface3
             : root.emphasized ? VekronaTheme.c.selected
             : mouse.containsMouse ? VekronaTheme.c.surface2 : "transparent"
    }

    Row {
        id: content
        x: VekronaTheme.space2
        anchors.verticalCenter: parent.verticalCenter
        spacing: VekronaTheme.space1

        Item {
            id: iconBox
            visible: root.icon !== "" || root.keepIconSlot
            width: VekronaTheme.iconS
            height: VekronaTheme.iconS
            anchors.verticalCenter: parent.verticalCenter

            Pictogram {
                name: root.icon
                filled: root.filled
            }
        }

        Label {
            visible: root.value !== ""
            anchors.verticalCenter: parent.verticalCenter
            style: VekronaTheme.type.label
            text: root.value
            width: Math.max(implicitWidth, root.valueMinWidth)
        }
    }

    Label {
        id: trailingLabel
        visible: root.trailing !== ""
        anchors.right: parent.right
        anchors.rightMargin: VekronaTheme.space2
        anchors.verticalCenter: parent.verticalCenter
        style: VekronaTheme.type.label
        color: VekronaTheme.c.inkMuted
        text: root.trailing
    }

    FocusRing {
        shown: root.activeFocus
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: event => event.button === Qt.RightButton ? root.rightClicked() : root.clicked()
        onWheel: event => root.wheel(event.angleDelta.y)
    }
}

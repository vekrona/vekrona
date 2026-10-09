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
    default property alias extra: iconBox.data

    signal clicked
    signal rightClicked
    signal wheel(int delta)

    implicitHeight: VekronaTheme.sizeTarget
    implicitWidth: 2 * VekronaTheme.space2 + content.width + overhang

    Accessible.role: Accessible.Button
    Accessible.name: ariaName
    activeFocusOnTab: true
    Keys.onReturnPressed: clicked()
    Keys.onSpacePressed: clicked()

    Rectangle {
        anchors.fill: parent
        color: mouse.pressed ? VekronaTheme.c.surface3 : mouse.containsMouse ? VekronaTheme.c.surface2 : "transparent"
    }

    Selection {
        shown: root.emphasized
    }

    Row {
        id: content
        x: VekronaTheme.space2
        anchors.verticalCenter: parent.verticalCenter
        spacing: VekronaTheme.space1

        Item {
            id: iconBox
            visible: root.icon !== ""
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
        }
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

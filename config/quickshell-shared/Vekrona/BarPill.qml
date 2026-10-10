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
    // The content at its natural width. The value elides when the pill is narrower.
    readonly property real valueNaturalWidth: Math.max(valueLabel.implicitWidth, valueMinWidth)
    readonly property real trailingWidth: trailing !== "" ? VekronaTheme.space4 + trailingLabel.implicitWidth : 0
    readonly property real contentWidth: (iconBox.visible ? iconBox.width : 0)
        + (iconBox.visible && valueLabel.visible ? content.spacing : 0)
        + (valueLabel.visible ? valueNaturalWidth : 0)

    implicitWidth: 2 * VekronaTheme.space2 + contentWidth + trailingWidth + overhang

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
                color: root.enabled ? VekronaTheme.c.ink : VekronaTheme.c.inkDisabled
            }
        }

        Label {
            id: valueLabel
            visible: root.value !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(root.valueNaturalWidth, Math.max(0, root.width - 2 * VekronaTheme.space2 - root.overhang
                - root.trailingWidth - (iconBox.visible ? iconBox.width + content.spacing : 0)))
            elide: Text.ElideRight
            style: VekronaTheme.type.label
            color: root.enabled ? VekronaTheme.c.ink : VekronaTheme.c.inkDisabled
            text: root.value
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

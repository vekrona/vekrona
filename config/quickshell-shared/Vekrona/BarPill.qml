import QtQuick
import "."

Item {
    id: root

    property string icon
    property string value
    property bool emphasized: false
    property bool filled: false
    property string ariaName
    // Unread count in a badge at the icon's top right corner. -1 has no badge; 0 hides it but keeps the room for it.
    property int badgeCount: -1
    // The widest value this pill will show. The pill reserves its width, so a changing value does not shift its neighbours.
    property string widestValue
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
    readonly property real trailingWidth: trailing !== "" ? VekronaTheme.space4 + trailingLabel.implicitWidth : 0
    readonly property real contentWidth: (iconBox.visible ? iconBox.width : 0)
        + (iconBox.visible && valueLabel.visible ? content.spacing : 0)
        + (valueLabel.visible ? valueLabel.implicitWidth : 0)

    implicitWidth: Math.ceil(2 * VekronaTheme.space2 + contentWidth + trailingWidth + badge.overhang)

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

            Badge {
                id: badge
                count: root.badgeCount
            }
        }

        FixedWidthLabel {
            id: valueLabel
            visible: root.value !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(valueLabel.implicitWidth, Math.max(0, root.width - 2 * VekronaTheme.space2 - badge.overhang
                - root.trailingWidth - (iconBox.visible ? iconBox.width + content.spacing : 0)))
            elide: Text.ElideRight
            style: VekronaTheme.type.label
            color: root.enabled ? VekronaTheme.c.ink : VekronaTheme.c.inkDisabled
            text: root.value
            widest: root.widestValue
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

import QtQuick
import "."

Item {
    id: root

    property string icon
    property string value
    property bool emphasized: false
    property bool filled: false
    property string ariaName
    // Unread count: any count above 0 shows a dot at the icon's top right corner, inside the pill's right padding.
    property int badgeCount: 0
    // Dims the dot, as a Pulse of the count says.
    property bool badgeDimmed: false
    // The values this pill may show, as one string or a list of strings. The pill reserves the width of the widest, so a
    // changing value does not shift its neighbours.
    property var widestValue: ""
    // Reserves the icon's slot even with no icon, so rows that show a mark only on one of them stay aligned.
    property bool keepIconSlot: false
    // The color of the pill's icon and value, which a pill that draws its own mark uses too.
    readonly property color ink: enabled ? VekronaTheme.c.ink : VekronaTheme.c.inkDisabled
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

    implicitWidth: Math.ceil(2 * VekronaTheme.space2 + contentWidth + trailingWidth)

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
                color: root.ink
            }

            Badge {
                id: badge
                count: root.badgeCount
                dimmed: root.badgeDimmed
            }
        }

        FixedWidthLabel {
            id: valueLabel
            visible: root.value !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(valueLabel.implicitWidth, Math.max(0, root.width - 2 * VekronaTheme.space2
                - root.trailingWidth - (iconBox.visible ? iconBox.width + content.spacing : 0)))
            elide: Text.ElideRight
            // Centered, so the slack of a value narrower than the widest splits between both neighbours instead of piling up on the left one.
            alignment: Text.AlignHCenter
            style: VekronaTheme.type.label
            color: root.ink
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

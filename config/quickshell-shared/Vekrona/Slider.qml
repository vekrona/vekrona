import QtQuick
import "."

Item {
    id: root

    property real value: 0
    property real step: 0.05
    property string ariaName

    signal moved(real value)

    implicitWidth: 12 * VekronaTheme.space4
    implicitHeight: VekronaTheme.sizeTarget

    Accessible.role: Accessible.Slider
    Accessible.name: ariaName
    activeFocusOnTab: true
    Keys.onLeftPressed: moved(Math.max(0, value - step))
    Keys.onRightPressed: moved(Math.min(1, value + step))

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        x: thumb.width / 2
        width: parent.width - thumb.width
        height: VekronaTheme.space1
        color: VekronaTheme.c.line

        Rectangle {
            width: root.value * parent.width
            height: parent.height
            color: VekronaTheme.c.accent
        }
    }

    Rectangle {
        id: thumb
        anchors.verticalCenter: parent.verticalCenter
        x: root.value * track.width
        width: VekronaTheme.space2
        height: VekronaTheme.iconS
        color: VekronaTheme.c.ink
    }

    FocusRing {
        shown: root.activeFocus
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onPressed: event => root.moved(root.fraction(event.x))
        onPositionChanged: event => root.moved(root.fraction(event.x))
    }

    function fraction(x: real): real {
        return Math.max(0, Math.min(1, (x - thumb.width / 2) / track.width));
    }
}

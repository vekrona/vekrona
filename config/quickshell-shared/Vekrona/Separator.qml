import QtQuick
import "."

Item {
    implicitWidth: VekronaTheme.borderHair + 3 * VekronaTheme.space1
    implicitHeight: VekronaTheme.sizeBar

    Rectangle {
        anchors.centerIn: parent
        width: VekronaTheme.borderHair
        height: 0.6 * VekronaTheme.sizeBar
        color: VekronaTheme.c.line
    }
}

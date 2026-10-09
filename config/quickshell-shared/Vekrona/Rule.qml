import QtQuick
import QtQuick.Layouts
import "."

// A full-width horizontal hairline between the blocks of a column.
// Separator is the bar's vertical divider.
Item {
    Layout.fillWidth: true
    implicitHeight: VekronaTheme.borderHair + 2 * VekronaTheme.space2

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: VekronaTheme.borderHair
        color: VekronaTheme.c.line
    }
}

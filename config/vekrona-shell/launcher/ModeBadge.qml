import QtQuick
import "../Vekrona"

// The mode the search field is in, left of the query: a flat rectangle, not a pill.
Rectangle {
    id: root

    property string text

    implicitWidth: label.implicitWidth + 2 * VekronaTheme.space2
    implicitHeight: label.implicitHeight + VekronaTheme.space2
    color: VekronaTheme.c.surface3

    Label {
        id: label
        anchors.centerIn: parent
        style: VekronaTheme.type.label
        text: root.text
    }
}

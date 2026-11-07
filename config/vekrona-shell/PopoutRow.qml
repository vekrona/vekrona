import QtQuick
import QtQuick.Layouts
import "Vekrona"

// A row of a popout that is information with buttons after it, which a BarPill is not: a BarPill is one button
// all over. The name elides before the buttons give way.
RowLayout {
    id: root

    property string icon
    property string text
    // Muted text after the name.
    property string detail
    // The buttons, usually BarPills.
    default property alias actions: buttons.data

    Layout.fillWidth: true
    Layout.minimumHeight: VekronaTheme.sizeTarget
    spacing: VekronaTheme.space1

    Pictogram {
        Layout.leftMargin: VekronaTheme.space2
        name: root.icon
    }

    Label {
        Layout.fillWidth: true
        elide: Text.ElideRight
        style: VekronaTheme.type.label
        text: root.text
    }

    Label {
        visible: root.detail !== ""
        Layout.rightMargin: VekronaTheme.space2
        style: VekronaTheme.type.label
        color: VekronaTheme.c.inkMuted
        text: root.detail
    }

    RowLayout {
        id: buttons
        spacing: 0
    }
}

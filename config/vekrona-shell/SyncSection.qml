import QtQuick
import QtQuick.Layouts
import "Vekrona"

// A titled block of rows in the Sync popout. The caller hides it with `visible` while it has no rows.
ColumnLayout {
    id: root

    property string title
    default property alias rows: body.data

    Layout.fillWidth: true
    spacing: 0

    Label {
        Layout.leftMargin: VekronaTheme.space2
        Layout.topMargin: VekronaTheme.space2
        style: VekronaTheme.type.caption
        color: VekronaTheme.c.inkMuted
        text: root.title
    }

    ColumnLayout {
        id: body
        Layout.fillWidth: true
        spacing: 0
    }
}

import QtQuick
import QtQuick.Layouts
import "Vekrona"

// A line of the VPN popout under the state: muted caption text, or a failure in danger ink. It shows while it has text.
Label {
    property bool danger: false

    visible: text !== ""
    Layout.fillWidth: true
    Layout.leftMargin: VekronaTheme.space2
    Layout.rightMargin: VekronaTheme.space2
    wrapMode: Text.Wrap
    color: danger ? VekronaTheme.c.dangerInk : VekronaTheme.c.inkMuted
    style: danger ? VekronaTheme.type.body : VekronaTheme.type.caption
}

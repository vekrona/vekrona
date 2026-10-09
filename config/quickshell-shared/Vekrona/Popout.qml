import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "."

PanelWindow {
    id: root

    required property Item anchorItem
    property bool open: false
    default property alias content: body.data

    signal dismissed

    visible: open
    screen: anchorItem.QsWindow.window?.screen ?? null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "vekrona-popout"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    anchors.top: true
    anchors.left: true
    margins.top: VekronaTheme.sizeBar
    margins.left: Math.max(0, Math.min(anchorItem.mapToItem(null, 0, 0).x, (anchorItem.QsWindow.window?.width ?? 0) - width))
    implicitWidth: body.implicitWidth + 2 * VekronaTheme.space4
    implicitHeight: body.implicitHeight + 2 * VekronaTheme.space4

    Rectangle {
        anchors.fill: parent
        color: VekronaTheme.c.surface1
        border.width: VekronaTheme.borderHair
        border.color: VekronaTheme.c.line
    }

    FocusScope {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: root.dismissed()

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: VekronaTheme.space4
        }
    }
}

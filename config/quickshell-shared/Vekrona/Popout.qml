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
    // Opaque, so the compositor never blends the popout with what is behind it, which flickers on NVIDIA.
    color: VekronaTheme.c.surface1
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

    // A popout keeps the focus of its last use, so reopening it would resume on whatever was focused then, a text field
    // that Enter then triggers. Opening parks the focus on an item that does nothing, and Tab starts from the top.
    Connections {
        target: root

        function onOpenChanged(): void {
            if (root.open)
                parking.forceActiveFocus();
        }
    }

    // The window takes a new size only after a round trip to the compositor. Everything inside is therefore sized from
    // the implicit size, not from the window: a layout that filled the old window would recenter its shrunken content in it.
    Rectangle {
        width: root.implicitWidth
        height: root.implicitHeight
        color: "transparent"
        border.width: VekronaTheme.borderHair
        border.color: VekronaTheme.c.line
    }

    FocusScope {
        width: root.implicitWidth
        height: root.implicitHeight
        focus: true
        Keys.onEscapePressed: root.dismissed()

        Item {
            id: parking
        }

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: VekronaTheme.space4
        }
    }
}

import QtQuick
import Quickshell
import Quickshell.Wayland
import "Vekrona"

PanelWindow {
    id: root

    required property var targetScreen
    property bool active: false

    signal dismissed

    visible: active
    screen: targetScreen
    anchors.top: true
    anchors.left: true
    anchors.right: true
    anchors.bottom: true
    margins.top: VekronaTheme.sizeBar
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "vekrona-popout-catcher"

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: root.dismissed()
    }
}

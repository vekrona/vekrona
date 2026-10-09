import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "Vekrona"

PanelWindow {
    id: root

    required property var modelData
    required property var launcher
    property var openPopout: null

    function togglePopout(popout) {
        openPopout = openPopout === popout ? null : popout;
    }

    screen: modelData
    anchors.top: true
    anchors.left: true
    anchors.right: true
    implicitHeight: VekronaTheme.sizeBar
    color: VekronaTheme.c.surface1
    WlrLayershell.namespace: "vekrona-bar"

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: VekronaTheme.borderHair
        color: VekronaTheme.c.line
    }

    RowLayout {
        anchors.left: parent.left
        height: parent.height
        spacing: 0

        LauncherButton {
            launcher: root.launcher
        }

        Desktops {}

        Separator {}

        WindowTitle {
            Layout.maximumWidth: root.width / 3
        }
    }

    RowLayout {
        anchors.right: parent.right
        height: parent.height
        spacing: 0

        Tray {}

        Weather {
            bar: root
        }

        Perf {}

        Sound {
            bar: root
        }

        Network {
            bar: root
        }

        Battery {}

        Agent {}

        Calendar {
            bar: root
        }

        Clock {}
    }

    PanelWindow {
        visible: root.openPopout !== null
        screen: root.screen
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
            onClicked: root.openPopout = null
        }
    }
}

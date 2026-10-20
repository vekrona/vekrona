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

    onOpenPopoutChanged: {
        if (openPopout !== null)
            KeyboardSurface.claim(root);
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

        CaffeinePill {
            bar: root
        }

        Tray {}

        Weather {
            bar: root
        }

        Perf {}

        KeyboardLayout {
            bar: root
        }

        Sound {
            bar: root
        }

        Network {
            bar: root
        }

        Battery {}

        Agent {
            launcher: root.launcher
        }

        NotificationsButton {}

        Calendar {
            bar: root
        }
    }

    // The launcher, the notification centre or a popout of another bar came up and holds the keyboard now.
    Connections {
        target: KeyboardSurface

        function onClaimed(owner: var): void {
            if (owner !== root)
                root.openPopout = null;
        }
    }

    Catcher {
        targetScreen: root.screen
        active: root.openPopout !== null
        onDismissed: root.openPopout = null
    }
}

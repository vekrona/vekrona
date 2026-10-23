import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import "Vekrona"

Row {
    Repeater {
        model: SystemTray.items

        Item {
            id: item

            required property SystemTrayItem modelData
            readonly property bool hiddenDuplicate: modelData.id === "nm-applet" || modelData.id.startsWith("blueman")

            visible: !hiddenDuplicate
            width: VekronaTheme.iconS + 2 * VekronaTheme.space2
            height: VekronaTheme.sizeTarget

            Rectangle {
                anchors.fill: parent
                color: mouse.pressed ? VekronaTheme.c.surface3 : mouse.containsMouse ? VekronaTheme.c.surface2 : "transparent"
            }

            TintedIcon {
                anchors.centerIn: parent
                source: item.modelData.icon
                tint: VekronaTheme.c.ink
            }

            QsMenuAnchor {
                id: menu
                menu: item.modelData.menu
                anchor.item: item
                anchor.edges: Edges.Bottom | Edges.Left
                anchor.gravity: Edges.Bottom | Edges.Right
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // An icon with a menu shows it; one without asks the app to act, as for a window to open. Opening the
                // menu of an icon without one is an error the shell logs.
                onClicked: item.modelData.hasMenu ? menu.open() : item.modelData.activate()
            }
        }
    }
}

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
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: event => {
                    if (event.button === Qt.RightButton || item.modelData.onlyMenu)
                        menu.open();
                    else
                        item.modelData.activate();
                }
            }
        }
    }
}

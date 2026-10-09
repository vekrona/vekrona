import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets
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

            IconImage {
                id: glyph
                anchors.centerIn: parent
                implicitSize: VekronaTheme.iconS
                source: item.modelData.icon
                layer.enabled: true
                visible: false
            }

            Rectangle {
                id: ink
                anchors.fill: glyph
                color: VekronaTheme.c.ink
                layer.enabled: true
                visible: false
            }

            MultiEffect {
                anchors.fill: glyph
                source: ink
                maskEnabled: true
                maskSource: glyph
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

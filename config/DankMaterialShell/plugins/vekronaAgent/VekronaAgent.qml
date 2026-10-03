import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property string unreadFilePath: StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/vekrona/errors/unread"
    property int unreadCount: 0

    function parseUnread(raw) {
        const n = parseInt(String(raw).trim(), 10);
        return (Number.isFinite(n) && n > 0) ? n : 0;
    }

    FileView {
        id: unreadFile
        path: root.unreadFilePath
        watchChanges: true
        onLoaded: root.unreadCount = root.parseUnread(text())
        onLoadFailed: root.unreadCount = 0
        onFileChanged: reload()
    }

    pillClickAction: function () {
        Quickshell.execDetached(["vekrona-agent", "--pick"]);
    }

    pillRightClickAction: function () {
        Quickshell.execDetached(["vekrona-error", "pick"]);
    }

    readonly property string tooltipText: "Open coding agent (right-click: pick a recorded error)"

    Loader {
        id: tooltipLoader
        active: false
        sourceComponent: DankTooltip {}
    }

    function showTooltip(item) {
        tooltipLoader.active = true;
        if (!tooltipLoader.item)
            return;
        const screen = root.parentScreen || Screen;
        const edge = root.axis?.edge ?? "top";
        const gap = root.barThickness + root.barSpacing + Theme.spacingXS;
        const pos = item.mapToItem(null, item.width / 2, item.height / 2);
        let x = pos.x;
        let y = pos.y;
        let alignLeft = false;
        let alignRight = false;
        if (root.isVertical) {
            alignLeft = edge === "left";
            alignRight = !alignLeft;
            x = alignLeft ? gap : screen.width - gap;
        } else {
            y = edge === "bottom" ? screen.height - gap : gap;
        }
        tooltipLoader.item.show(root.tooltipText, x, y, screen, alignLeft, alignRight);
    }

    function hideTooltip() {
        if (tooltipLoader.item)
            tooltipLoader.item.hide();
        tooltipLoader.active = false;
    }

    horizontalBarPill: Component {
        Item {
            id: horizontalContent
            implicitWidth: icon.width
            implicitHeight: root.widgetThickness

            DankIcon {
                id: icon
                anchors.centerIn: parent
                name: "smart_toy"
                size: Theme.barIconSize(root.barThickness, -4, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                color: Theme.widgetIconColor
            }

            Rectangle {
                visible: root.unreadCount > 0
                width: Math.max(12, unreadBadgeText.implicitWidth + 4)
                height: 12
                radius: height / 2
                color: Theme.error
                anchors.right: icon.right
                anchors.top: icon.top
                anchors.rightMargin: -4
                anchors.topMargin: -4

                StyledText {
                    id: unreadBadgeText
                    anchors.centerIn: parent
                    text: root.unreadCount > 99 ? "99+" : String(root.unreadCount)
                    font.pixelSize: 9
                    color: Theme.errorText
                }
            }

            MouseArea {
                id: horizontalHoverArea
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                hoverEnabled: true
                onEntered: root.showTooltip(horizontalHoverArea)
                onExited: root.hideTooltip()
            }
        }
    }

    verticalBarPill: Component {
        Item {
            id: verticalContent
            implicitWidth: root.widgetThickness
            implicitHeight: icon.height

            DankIcon {
                id: icon
                anchors.centerIn: parent
                name: "smart_toy"
                size: Theme.barIconSize(root.barThickness, -4, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                color: Theme.widgetIconColor
            }

            Rectangle {
                visible: root.unreadCount > 0
                width: Math.max(12, unreadBadgeTextVertical.implicitWidth + 4)
                height: 12
                radius: height / 2
                color: Theme.error
                anchors.right: icon.right
                anchors.top: icon.top
                anchors.rightMargin: -4
                anchors.topMargin: -4

                StyledText {
                    id: unreadBadgeTextVertical
                    anchors.centerIn: parent
                    text: root.unreadCount > 99 ? "99+" : String(root.unreadCount)
                    font.pixelSize: 9
                    color: Theme.errorText
                }
            }

            MouseArea {
                id: verticalHoverArea
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                hoverEnabled: true
                onEntered: root.showTooltip(verticalHoverArea)
                onExited: root.hideTooltip()
            }
        }
    }
}

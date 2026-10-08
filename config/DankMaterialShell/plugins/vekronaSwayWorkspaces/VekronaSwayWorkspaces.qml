import QtQuick
import Quickshell.I3
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property int lowestAlwaysShown: 1
    readonly property int highestAlwaysShown: 5
    readonly property int highestWorkspace: 10

    // size-target from the design tokens: the minimum clickable extent.
    readonly property int targetSize: 32
    readonly property var tokens: Theme.currentThemeData.tokens

    property var occupiedNumbers: []

    Component.onCompleted: {
        if (!tokens)
            console.error("vekronaSwayWorkspaces: the active theme carries no `tokens` object; run vekrona-render-theme");
    }

    function swayWorkspaces() {
        return I3.workspaces?.values ?? [];
    }

    function workspaceFor(number) {
        return swayWorkspaces().find(ws => ws.num === number) ?? null;
    }

    readonly property var displayedNumbers: {
        const numbers = [];
        for (let n = lowestAlwaysShown; n <= highestWorkspace; n++) {
            if (n <= highestAlwaysShown || workspaceFor(n) !== null)
                numbers.push(n);
        }
        return numbers;
    }

    function isOccupied(number) {
        return root.occupiedNumbers.includes(number);
    }

    function collectOccupiedWorkspaces(node) {
        const occupied = [];
        function walk(n) {
            if (!n)
                return;
            if (n.type === "workspace" && typeof n.num === "number" && n.num !== -1) {
                const hasContent = (n.nodes && n.nodes.length > 0) || (n.floating_nodes && n.floating_nodes.length > 0);
                if (hasContent)
                    occupied.push(n.num);
            }
            const children = (n.nodes || []).concat(n.floating_nodes || []);
            children.forEach(walk);
        }
        walk(node);
        return occupied;
    }

    function refreshOccupied() {
        Proc.runCommand("vekronaSwayWorkspaces.tree", ["swaymsg", "-t", "get_tree"], (stdout, exitCode) => {
            if (exitCode !== 0)
                return;
            try {
                root.occupiedNumbers = root.collectOccupiedWorkspaces(JSON.parse(stdout));
            } catch (e) {
                console.warn("vekronaSwayWorkspaces: failed to parse sway tree:", e);
            }
        });
    }

    I3IpcListener {
        subscriptions: ["window", "workspace"]
        onIpcEvent: root.refreshOccupied()
        Component.onCompleted: root.refreshOccupied()
    }

    function switchTo(number) {
        I3.dispatch(`workspace number ${number}`);
    }

    function switchByOffset(offset) {
        const numbers = root.displayedNumbers;
        if (numbers.length === 0)
            return;
        const focused = swayWorkspaces().find(ws => ws.focused === true);
        const currentIndex = focused ? numbers.indexOf(focused.num) : -1;
        const baseIndex = currentIndex === -1 ? 0 : currentIndex;
        const nextIndex = Math.max(0, Math.min(numbers.length - 1, baseIndex + offset));
        if (nextIndex !== currentIndex)
            switchTo(numbers[nextIndex]);
    }

    function labelColor(focused, occupied, urgent) {
        if (urgent)
            return tokens.dangerInk;
        if (focused)
            return tokens.accentInk;
        if (occupied)
            return Theme.surfaceText;
        return Theme.surfaceVariantText;
    }

    horizontalBarPill: Component {
        Item {
            id: horizontalContent
            implicitWidth: pillRow.implicitWidth
            implicitHeight: root.widgetThickness

            Row {
                id: pillRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                Repeater {
                    model: root.displayedNumbers

                    Item {
                        id: pill
                        readonly property int number: modelData
                        readonly property var workspace: root.workspaceFor(number)
                        readonly property bool focused: workspace?.focused ?? false
                        readonly property bool urgent: workspace?.urgent ?? false
                        readonly property bool occupied: root.isOccupied(number)

                        implicitWidth: Math.max(label.implicitWidth, root.targetSize)
                        implicitHeight: Math.max(root.widgetThickness, root.targetSize)
                        width: implicitWidth
                        height: implicitHeight

                        Rectangle {
                            anchors.fill: parent
                            radius: 0
                            color: Theme.surfaceContainerHigh
                            visible: pillMouse.containsMouse
                        }

                        StyledText {
                            id: label
                            anchors.centerIn: parent
                            text: pill.number
                            color: root.labelColor(pill.focused, pill.occupied, pill.urgent)
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: pill.focused ? Font.DemiBold : Font.Normal

                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.shortDuration
                                }
                            }
                        }

                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: label.implicitWidth
                            height: 2
                            radius: 0
                            color: Theme.primary
                            opacity: pill.focused ? 1 : 0

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: Theme.shortDuration
                                    easing.type: Theme.standardEasing
                                }
                            }
                        }

                        MouseArea {
                            id: pillMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.switchTo(pill.number)
                        }
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                onWheel: wheelEvent => root.switchByOffset(wheelEvent.angleDelta.y < 0 ? 1 : -1)
            }
        }
    }

    verticalBarPill: Component {
        Item {
            id: verticalContent
            implicitWidth: root.widgetThickness
            implicitHeight: pillColumn.implicitHeight

            Column {
                id: pillColumn
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingS

                Repeater {
                    model: root.displayedNumbers

                    Item {
                        id: pill
                        readonly property int number: modelData
                        readonly property var workspace: root.workspaceFor(number)
                        readonly property bool focused: workspace?.focused ?? false
                        readonly property bool urgent: workspace?.urgent ?? false
                        readonly property bool occupied: root.isOccupied(number)

                        implicitWidth: Math.max(root.widgetThickness, root.targetSize)
                        implicitHeight: Math.max(label.implicitHeight, root.targetSize)
                        width: implicitWidth
                        height: implicitHeight

                        Rectangle {
                            anchors.fill: parent
                            radius: 0
                            color: Theme.surfaceContainerHigh
                            visible: pillMouse.containsMouse
                        }

                        StyledText {
                            id: label
                            anchors.centerIn: parent
                            text: pill.number
                            color: root.labelColor(pill.focused, pill.occupied, pill.urgent)
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: pill.focused ? Font.DemiBold : Font.Normal

                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.shortDuration
                                }
                            }
                        }

                        Rectangle {
                            anchors.left: parent.left
                            width: 2
                            height: parent.height
                            radius: 0
                            color: Theme.primary
                            opacity: pill.focused ? 1 : 0

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: Theme.shortDuration
                                    easing.type: Theme.standardEasing
                                }
                            }
                        }

                        MouseArea {
                            id: pillMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.switchTo(pill.number)
                        }
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                onWheel: wheelEvent => root.switchByOffset(wheelEvent.angleDelta.y < 0 ? 1 : -1)
            }
        }
    }
}

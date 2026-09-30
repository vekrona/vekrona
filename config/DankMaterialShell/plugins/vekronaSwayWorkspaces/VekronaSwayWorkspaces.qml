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

    property var occupiedNumbers: []

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

    function pillColor(focused, occupied, urgent) {
        if (urgent)
            return Theme.error;
        if (focused)
            return Theme.primary;
        if (occupied)
            return Theme.secondary;
        return Theme.surfaceTextAlpha;
    }

    function pillTextColor(focused, urgent) {
        return (focused || urgent) ? Theme.surfaceContainer : Theme.surfaceText;
    }

    horizontalBarPill: Component {
        Item {
            id: horizontalContent
            implicitWidth: pillRow.implicitWidth
            implicitHeight: root.widgetThickness

            Row {
                id: pillRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                Repeater {
                    model: root.displayedNumbers

                    Rectangle {
                        id: pill
                        readonly property int number: modelData
                        readonly property var workspace: root.workspaceFor(number)
                        readonly property bool focused: workspace?.focused ?? false
                        readonly property bool urgent: workspace?.urgent ?? false
                        readonly property bool occupied: root.isOccupied(number)

                        width: focused ? Math.max(root.widgetThickness * 0.85, 22) : Math.max(root.widgetThickness * 0.6, 16)
                        height: Math.max(root.widgetThickness * 0.6, 16)
                        radius: Theme.cornerRadius
                        color: root.pillColor(focused, occupied, urgent)

                        Behavior on width {
                            NumberAnimation {
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.shortDuration
                            }
                        }

                        StyledText {
                            anchors.centerIn: parent
                            text: pill.number
                            color: root.pillTextColor(pill.focused, pill.urgent)
                            font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                            font.weight: pill.focused ? Font.DemiBold : Font.Normal
                        }

                        MouseArea {
                            anchors.fill: parent
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
                spacing: Theme.spacingXS

                Repeater {
                    model: root.displayedNumbers

                    Rectangle {
                        id: pill
                        readonly property int number: modelData
                        readonly property var workspace: root.workspaceFor(number)
                        readonly property bool focused: workspace?.focused ?? false
                        readonly property bool urgent: workspace?.urgent ?? false
                        readonly property bool occupied: root.isOccupied(number)

                        width: Math.max(root.widgetThickness * 0.6, 16)
                        height: focused ? Math.max(root.widgetThickness * 0.85, 22) : Math.max(root.widgetThickness * 0.6, 16)
                        radius: Theme.cornerRadius
                        color: root.pillColor(focused, occupied, urgent)

                        Behavior on height {
                            NumberAnimation {
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.shortDuration
                            }
                        }

                        StyledText {
                            anchors.centerIn: parent
                            text: pill.number
                            color: root.pillTextColor(pill.focused, pill.urgent)
                            font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                            font.weight: pill.focused ? Font.DemiBold : Font.Normal
                        }

                        MouseArea {
                            anchors.fill: parent
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

import QtQuick
import Quickshell.I3
import Quickshell.Io
import "Vekrona"

Row {
    id: root

    readonly property int lowestAlwaysShown: 1
    readonly property int highestAlwaysShown: 5
    readonly property int highestWorkspace: 10

    property var occupiedNumbers: []
    property bool treeStale: false

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
            (n.nodes || []).concat(n.floating_nodes || []).forEach(walk);
        }
        walk(node);
        return occupied;
    }

    function refreshOccupied() {
        if (tree.running) {
            treeStale = true;
            return;
        }
        tree.running = true;
    }

    function switchTo(number) {
        I3.dispatch(`workspace number ${number}`);
    }

    function switchByOffset(offset) {
        const numbers = displayedNumbers;
        const focused = swayWorkspaces().find(ws => ws.focused === true);
        const currentIndex = focused ? numbers.indexOf(focused.num) : -1;
        const nextIndex = Math.max(0, Math.min(numbers.length - 1, (currentIndex === -1 ? 0 : currentIndex) + offset));
        if (nextIndex !== currentIndex)
            switchTo(numbers[nextIndex]);
    }

    function labelColor(focused, occupied, urgent) {
        if (urgent)
            return VekronaTheme.c.dangerInk;
        return focused || occupied ? VekronaTheme.c.ink : VekronaTheme.c.inkMuted;
    }

    Process {
        id: tree
        command: ["swaymsg", "-t", "get_tree"]
        stdout: StdioCollector {
            onStreamFinished: root.occupiedNumbers = root.collectOccupiedWorkspaces(JSON.parse(text))
        }
        onExited: exitCode => {
            if (exitCode !== 0)
                console.error("vekrona-shell: swaymsg -t get_tree exited with", exitCode);
            if (root.treeStale) {
                root.treeStale = false;
                running = true;
            }
        }
    }

    I3IpcListener {
        subscriptions: ["window", "workspace"]
        onIpcEvent: root.refreshOccupied()
        Component.onCompleted: root.refreshOccupied()
    }

    WheelHandler {
        onWheel: event => root.switchByOffset(event.angleDelta.y < 0 ? 1 : -1)
    }

    Repeater {
        model: root.displayedNumbers

        Item {
            id: desktop

            required property int modelData
            readonly property var workspace: root.workspaceFor(modelData)
            readonly property bool focused: workspace?.focused ?? false

            width: Math.max(label.implicitWidth, VekronaTheme.sizeTarget)
            height: VekronaTheme.sizeTarget

            Rectangle {
                anchors.fill: parent
                color: VekronaTheme.c.surface2
                visible: mouse.containsMouse
            }

            Selection {
                shown: desktop.focused
            }

            Label {
                id: label
                anchors.centerIn: parent
                style: VekronaTheme.type.body
                font.weight: desktop.focused ? Font.DemiBold : Font.Normal
                text: desktop.modelData
                color: root.labelColor(desktop.focused, root.occupiedNumbers.includes(desktop.modelData), desktop.workspace?.urgent ?? false)
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchTo(desktop.modelData)
            }
        }
    }
}

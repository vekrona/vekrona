import QtQuick
import Quickshell.I3
import "Vekrona"

Row {
    id: root

    readonly property int lowestAlwaysShown: 1
    readonly property int highestAlwaysShown: 5
    readonly property int highestWorkspace: 10

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

    // A scroll step moves one desktop; a trackpad's small deltas add up to steps.
    function scroll(delta: real): void {
        const steps = notches.steps(delta);
        if (steps !== 0)
            switchByOffset(-steps);
    }

    function labelColor(focused, occupied, urgent) {
        if (urgent)
            return VekronaTheme.c.dangerInk;
        return focused || occupied ? VekronaTheme.c.ink : VekronaTheme.c.inkMuted;
    }

    WheelSteps {
        id: notches
    }

    WheelHandler {
        onWheel: event => root.scroll(event.angleDelta.y)
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
                color: root.labelColor(desktop.focused, Windows.occupiedNumbers.includes(desktop.modelData), desktop.workspace?.urgent ?? false)
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

import QtQuick
import "Vekrona"
import "."

// One frame split by a single line: the CPU load fills the left half and the memory use the right half. A click opens btop in a
// window of its own, and the next one closes it.
BarPill {
    id: root

    readonly property string monitorUnit: "vekrona-perf"
    readonly property string monitorClass: "vekrona.perf"

    // The frame is border, half, separator, half, border across.
    readonly property int halfWidth: 5

    // A fill that grows from the bottom of its half to its percent, inside the frame.
    component Fill: Rectangle {
        property int percent: 0

        anchors.bottom: parent.bottom
        anchors.bottomMargin: VekronaTheme.borderControl
        width: root.halfWidth
        height: Math.round((parent.height - 2 * VekronaTheme.borderControl) * percent / 100)
        color: root.ink
    }

    keepIconSlot: true
    ariaName: "CPU " + SystemLoad.cpuPercent + "%, memory " + SystemLoad.ramPercent + "%"
    onClicked: Exec.toggleDetached(monitorUnit, Exec.inTerminalAs(monitorClass, ["btop"]), Exec.home)

    Rectangle {
        // Whole pixels, so no edge of the frame blurs.
        x: Math.round((parent.width - width) / 2)
        anchors.verticalCenter: parent.verticalCenter
        width: 3 * VekronaTheme.borderControl + 2 * root.halfWidth
        height: VekronaTheme.iconS - 2
        color: "transparent"
        border.width: VekronaTheme.borderControl
        border.color: root.ink

        Fill {
            x: VekronaTheme.borderControl
            percent: SystemLoad.cpuPercent
        }

        Rectangle {
            x: VekronaTheme.borderControl + root.halfWidth
            y: VekronaTheme.borderControl
            width: VekronaTheme.borderControl
            height: parent.height - 2 * VekronaTheme.borderControl
            color: root.ink
        }

        Fill {
            x: 2 * VekronaTheme.borderControl + root.halfWidth
            percent: SystemLoad.ramPercent
        }
    }
}

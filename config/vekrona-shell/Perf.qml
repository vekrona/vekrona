import QtQuick
import Quickshell.Io
import "Vekrona"
import "."

Row {
    id: root

    property real previousBusy: 0
    property real previousTotal: 0
    property int cpuPercent: 0
    property int ramPercent: 0

    function readCpu(stat: string): void {
        const fields = stat.split("\n")[0].trim().split(/\s+/).slice(1, 9).map(Number);
        const idle = fields[3] + fields[4];
        const total = fields.reduce((sum, n) => sum + n, 0);
        const busy = total - idle;
        if (previousTotal > 0 && total > previousTotal)
            cpuPercent = Math.round(100 * (busy - previousBusy) / (total - previousTotal));
        previousBusy = busy;
        previousTotal = total;
    }

    function readRam(meminfo: string): void {
        const kb = key => Number(meminfo.match(new RegExp("^" + key + ":\\s+(\\d+)", "m"))[1]);
        ramPercent = Math.round(100 * (kb("MemTotal") - kb("MemAvailable")) / kb("MemTotal"));
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            stat.reload();
            meminfo.reload();
        }
    }

    FileView {
        id: stat
        path: "/proc/stat"
        onLoaded: root.readCpu(text())
    }

    FileView {
        id: meminfo
        path: "/proc/meminfo"
        onLoaded: root.readRam(text())
    }

    BarPill {
        icon: "speed"
        value: root.cpuPercent + " %"
        widestValue: "100 %"
        ariaName: "CPU load"
        onClicked: Exec.detached(Exec.inTerminal(["btop"]))
    }

    BarPill {
        icon: "memory"
        value: root.ramPercent + " %"
        widestValue: "100 %"
        ariaName: "Memory use"
        onClicked: Exec.detached(Exec.inTerminal(["btop"]))
    }
}

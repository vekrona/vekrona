pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// The CPU load and the memory use, read while somebody is there to see them. Every screen's bar shows the same two numbers, so
// they are read once. The sampling stops with the user's input: the screen locks after as many idle seconds as sampling waits,
// and nothing on a locked or switched-off screen is read, so a laptop's idle shell does not wake every two seconds for nobody.
Singleton {
    id: root

    readonly property int sampleMs: 2000
    // The idle time after which vekrona-idle.service locks the screen. A playing video inhibits idling and so keeps the sampling up.
    readonly property int idleSeconds: 300
    readonly property bool sampling: !idle.isIdle
    property real previousBusy: 0
    property real previousTotal: 0
    property int cpuPercent: 0
    property int ramPercent: 0

    function readCpu(stat: string): void {
        const fields = stat.split("\n")[0].trim().split(/\s+/).slice(1, 9).map(Number);
        const idleTime = fields[3] + fields[4];
        const total = fields.reduce((sum, n) => sum + n, 0);
        const busy = total - idleTime;
        if (previousTotal > 0 && total > previousTotal)
            cpuPercent = Math.round(100 * (busy - previousBusy) / (total - previousTotal));
        previousBusy = busy;
        previousTotal = total;
    }

    function readRam(meminfo: string): void {
        const kb = key => Number(meminfo.match(new RegExp("^" + key + ":\\s+(\\d+)", "m"))[1]);
        ramPercent = Math.round(100 * (kb("MemTotal") - kb("MemAvailable")) / kb("MemTotal"));
    }

    // The first sample after a pause would average the load over the whole pause, so it only sets the new start.
    onSamplingChanged: previousTotal = 0

    IdleMonitor {
        id: idle
        enabled: true
        timeout: root.idleSeconds
        respectInhibitors: true
    }

    Timer {
        interval: root.sampleMs
        running: root.sampling
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
}

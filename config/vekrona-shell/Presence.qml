pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Wayland

// Whether somebody can be looking at the screen: false from the idle time after which vekrona-idle.service locks the screen
// (and later switches it off) until the next input. Everything that moves or samples only for the eye gates on `here`, so that an
// idle laptop's shell does not wake for nobody: the CPU and memory sampling, and the Sync icon's turn. The compositor reports
// the idleness (ext-idle-notify), so this costs no wakeup of its own, and a playing video inhibits idling and so keeps it true.
// Qt does not stop a Timer or an animation when the surface is hidden or the output is off; the gate has to.
Singleton {
    id: root

    // The idle time after which vekrona-idle.service locks the screen.
    readonly property int idleSeconds: 300
    readonly property bool here: !idle.isIdle

    IdleMonitor {
        id: idle
        enabled: true
        timeout: root.idleSeconds
        respectInhibitors: true
    }
}

import QtQuick
import Quickshell
import "Vekrona"

// Reports once that no Super key is held, or that 60 s have passed. Neither Sway nor Qt sees Super go up reliably, and the
// user may not read the keyboards, so xremap (which sees every key) tells: it runs vekrona-super-state on every Super press and
// release, which writes 1 or 0 to /run/xremap/super-L and super-R. Create one per use: when xremap restarts, its directory is
// replaced, and a watcher made before that never sees the new files.
Scope {
    id: root

    readonly property int giveUpSec: 60

    signal released

    function check(): void {
        if (!left.settled || !right.settled)
            return;
        if (left.value === null && right.value === null)
            console.error("neither /run/xremap/super-L nor super-R exists: is xremap.service running?");
        if (left.value !== true && right.value !== true)
            released();
    }

    // The value is true when the key is down, false when up, and null when its file does not exist (the key was never pressed).
    component Key: StateFile {
        parse: text => text === "1"
        onRefreshed: root.check()
    }

    Key {
        id: left
        path: "/run/xremap/super-L"
    }

    Key {
        id: right
        path: "/run/xremap/super-R"
    }

    Timer {
        interval: root.giveUpSec * 1000
        running: true
        onTriggered: {
            console.error("Super still down after " + root.giveUpSec + " s");
            root.released();
        }
    }
}

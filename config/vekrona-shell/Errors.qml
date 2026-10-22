pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Vekrona"

// The errors `vekrona-error` has recorded and nobody has seen yet: the count the robot's dot shows on every screen, and the
// pulse of that dot. The launcher's error list follows the file that holds the count.
Singleton {
    id: root

    readonly property int unreadCount: unread.value
    // False until the unread file has been read once, or found missing.
    readonly property bool loaded: unread.settled
    readonly property bool pulsing: pulse.pulsing
    readonly property bool dim: pulse.dim

    // Emitted after every read of the unread file, whether or not the count changed.
    signal refreshed

    Pulse {
        id: pulse
        count: root.unreadCount
        known: root.loaded
    }

    StateFile {
        id: unread
        path: StateDir.path + "/errors/unread"
        absent: 0
        onRefreshed: root.refreshed()
        parse: text => {
            const n = parseInt(text.trim(), 10);
            return (Number.isFinite(n) && n > 0) ? n : 0;
        }
    }

    IpcHandler {
        target: "errors"

        // The robot's dot as compact JSON, for tests: {loaded, unread, pulsing}.
        function state(): string {
            return JSON.stringify({
                loaded: root.loaded,
                unread: root.unreadCount,
                pulsing: root.pulsing
            });
        }
    }
}

import QtQuick
import Quickshell.I3
import "."

// A swaymsg query whose JSON answer a widget follows. Sway emits one event per change, so a burst of events asks once more when the
// running query ends, not once each. Sway drops the IPC connections of queries that were running while the system slept, so the
// first failure is expected and the query is asked once more at once, on a fresh connection; only a failure right after a failed
// one, or one that could not start at all (no exit status), is reported, and then the next event or reconnect queries again. A
// query that has not answered after queryTimeoutMs is stopped and counts as one that could not start.
QtObject {
    id: root

    required property list<string> argv

    // The parsed answer of a query that succeeded.
    signal parsed(var json)
    // A query failed, expected or not: whatever the widget shows from the last answer is no longer known.
    signal unavailable()
    // A query failed for a reason to show; it has been logged.
    signal failed(string reason)

    property bool querying: false
    // A query was asked for while one was running.
    property bool dirty: false
    // The last query failed; the next one is the retry.
    property bool unreachable: false
    readonly property int queryTimeoutMs: 10000

    function run(): void {
        if (querying) {
            dirty = true;
            return;
        }
        querying = true;
        Exec.runWithin(argv, queryTimeoutMs, (code, stdout, stderr) => {
            querying = false;
            read(code, stdout, stderr);
            if (dirty) {
                dirty = false;
                run();
            }
        });
    }

    function read(code: int, stdout: string, stderr: string): void {
        if (code !== 0) {
            unavailable();
            if (unreachable || code < 0)
                failed(Exec.failure(argv, code, stderr));
            else
                dirty = true;
            unreachable = true;
            return;
        }
        let json;
        try {
            json = JSON.parse(stdout);
        } catch (e) {
            unavailable();
            console.error(JSON.stringify(argv) + " printed invalid JSON: " + e);
            failed("printed invalid JSON: " + e);
            return;
        }
        unreachable = false;
        parsed(json);
    }

    Component.onCompleted: run()

    property Connections reconnect: Connections {
        target: I3
        function onConnected(): void {
            root.run();
        }
    }
}

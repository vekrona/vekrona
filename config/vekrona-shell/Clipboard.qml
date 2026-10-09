import QtQuick
import Quickshell.Io
import "."

Picker {
    id: root

    property var history: []

    function entries(lines, query: string): var {
        const needle = query.toLowerCase();
        return lines.filter(line => line.slice(line.indexOf("\t") + 1).toLowerCase().includes(needle)).map(line => ({
                    label: line.slice(line.indexOf("\t") + 1),
                    line: line
                }));
    }

    ipcTarget: "clipboard"
    namespace: "vekrona-clipboard"
    placeholder: "Search clipboard history"
    items: entries(history, query)
    onChosen: item => Exec.detached(["bash", "-c", "set -eo pipefail; cliphist decode \"$1\" | wl-copy", "_", item.line])
    onOpenChanged: if (open)
        list.running = true

    Process {
        id: list
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            onStreamFinished: root.history = text.split("\n").filter(line => line !== "")
        }
        stderr: StdioCollector {
            onStreamFinished: if (text !== "")
                console.error("cliphist list: " + text)
        }
    }
}

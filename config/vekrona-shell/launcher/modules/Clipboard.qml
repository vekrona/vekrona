import ".."
import "../.." as Shell

LauncherModule {
    id: root

    // One `cliphist list` line is "<id>\t<preview>".
    function entry(line: string): var {
        const tab = line.indexOf("\t");
        return {
            line: line,
            id: line.slice(0, tab),
            text: line.slice(tab + 1)
        };
    }

    // Keeps cliphist's order (newest first); the descending score tells the host to keep it.
    function rows(output: string, text: string): var {
        const needle = text.toLowerCase();
        const matches = output.split("\n").filter(line => line !== "").map(entry).filter(item => item.text.toLowerCase().includes(needle));
        return matches.map((item, position) => ({
                    id: "clip:" + item.id,
                    title: item.text,
                    kind: "Clipboard",
                    score: (matches.length - position) / matches.length,
                    actions: [
                        {
                            id: "copy",
                            label: "Copy",
                            exec: ["bash", "-c", "set -eo pipefail; cliphist decode \"$1\" | wl-copy", "_", item.line]
                        },
                        {
                            id: "delete",
                            label: "Delete",
                            destructive: true,
                            run: () => root.deleteEntry(item)
                        }
                    ]
                }));
    }

    // Deletes the entry, then has the host query again. Returns false: the launcher stays open on the shorter list.
    function deleteEntry(item: var): bool {
        const argv = ["bash", "-c", "set -eo pipefail; printf '%s\\n' \"$1\" | cliphist delete", "_", item.line];
        Shell.Exec.runOr(argv, stdout => root.changed(), reason => launcher.toast("Couldn’t delete: " + reason));
        return false;
    }

    function query(text: string, reqId: int): var {
        const argv = ["cliphist", "list"];
        answerFrom(reqId, argv, (code, stdout, stderr) => code !== 0 ? [errorRow("read the clipboard history", Shell.Exec.failure(argv, code, stderr))] : rows(stdout, text));
        return null;
    }

    moduleId: "clip"
    title: "Clipboard"
    glyph: "content_paste"
    slash: "clip"
    global: false
}

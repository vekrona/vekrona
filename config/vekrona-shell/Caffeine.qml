pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The keep-awake session of `vekrona-caffeine`: its state, and the commands that start and end one.
Singleton {
    id: root

    // The spans a session can be started for in one click. Both the bar menu and the launcher offer these.
    readonly property var presets: ["1h", "2h", "5h", "12h", "24h"]
    // How close in time Firefox creates a download's partial file and the empty file with its real name.
    readonly property real sameBirthSeconds: 5
    // The exit status of `vekrona-caffeine` for input it refuses.
    readonly property int refusedExit: 2
    property bool active: false
    // What ends the session: "for" a span, "until" a time, "file" (a download) or "pid" (a process).
    property string kind: ""
    // Epoch seconds of the deadline of a "for" or "until" session, 0 for the others.
    property real endsAt: 0
    // The span a "for" session was started with, "" for the others.
    property string preset: ""
    // What the session is about, ready to show: the span, the time, the file's label or the app's name.
    property string target: ""
    property real now: Date.now()
    // The time left of a "for" or "until" session as H:MM, or as whole days (like 2d) from 24 hours on, "" for the others.
    readonly property string remaining: endsAt > 0 ? clock(Math.max(0, Math.ceil((endsAt * 1000 - now) / 60000))) : ""

    property var reading: null

    function clock(minutes: int): string {
        if (minutes >= 24 * 60)
            return Math.floor(minutes / (24 * 60)) + "d";
        return Math.floor(minutes / 60) + ":" + String(minutes % 60).padStart(2, "0");
    }

    function clear(): void {
        active = false;
        kind = "";
        endsAt = 0;
        preset = "";
        target = "";
    }

    // Applies the output of `vekrona-caffeine status`: `off`, or `kind=<k> end=<epoch|-> preset=<span|-> target=<rest>`.
    // An output that is neither is logged and leaves the state as it was.
    function apply(output: string): void {
        const status = output.trim();
        if (status === "off") {
            clear();
            return;
        }
        const match = /^kind=(for|until|file|pid) end=(\d+|-) preset=(\S+) target=(.*)$/.exec(status);
        if (!match) {
            console.error("Caffeine: cannot read the output of `vekrona-caffeine status`: " + status);
            return;
        }
        kind = match[1];
        endsAt = match[2] === "-" ? 0 : Number(match[2]);
        preset = match[3] === "-" ? "" : match[3];
        target = match[4];
        now = Date.now();
        active = true;
    }

    // Reads the state again. Only the newest read counts, so a slow one cannot overwrite a newer state.
    function refresh(): void {
        reading?.kill();
        reading = Exec.runChecked(["vekrona-caffeine", "status"], apply);
    }

    // Shows a message as a plain desktop notification, for the places that have no toast of their own, like the bar.
    function notify(message: string): void {
        Exec.check(["notify-send", "-a", "vekrona", "Keep-awake", message]);
    }

    // Runs a `vekrona-caffeine` command, like `["for", "2h"]`, and calls fail(reason) when it failed, with the first line of
    // what it said, so the user sees why. The command tells the shell to refresh, so the state is not read here.
    // Exit status refusedExit is the command refusing the input: that is the user's doing, so it is only warned about, below
    // the error pipeline. Any other failure is unexpected and is logged as an error, which records it.
    function start(args: list<string>, fail): void {
        const argv = ["vekrona-caffeine"].concat(args);
        Exec.run(argv, (code, stdout, stderr) => {
            if (code === 0)
                return;
            if (code === refusedExit) {
                const reason = stderr.trim().split("\n")[0] || "exited " + code;
                console.warn(JSON.stringify(argv) + " refused: " + reason);
                fail(reason);
            } else {
                fail(Exec.failure(argv, code, stderr));
            }
        });
    }

    function stop(fail): void {
        start(["off"], fail);
    }

    // Reads the output of the listing of downloads: the download folder and a newline, then one record per file,
    // "<name>/<birth>\t<size>\n". A name holds neither "/" nor anything else a record could be mistaken for, so the
    // newlines and tabs that a name may hold are safe. Throws on output of any other shape.
    function parseDownloadFiles(stdout: string): var {
        const split = stdout.indexOf("\n");
        if (split < 0)
            throw new Error("no download folder in " + JSON.stringify(stdout));
        const directory = stdout.slice(0, split);
        const record = /([^\/]*)\/(\d+(?:\.\d+)?)\t(\d+)\n/y;
        record.lastIndex = split + 1;
        const files = [];
        while (record.lastIndex < stdout.length) {
            const at = record.lastIndex;
            const match = record.exec(stdout);
            if (match === null)
                throw new Error("unreadable download record in " + JSON.stringify(stdout.slice(at)));
            files.push({
                birth: Number(match[2]),
                size: Number(match[3]),
                name: match[1],
                path: directory + "/" + match[1]
            });
        }
        return files;
    }

    // The rows {label, trailing, args} for start() of the files that are downloads in progress.
    function downloadRows(files: var): var {
        const partial = file => /\.(part|crdownload)$/.test(file.name);
        const parts = files.filter(file => file.name.endsWith(".part"));
        const placeholders = files.filter(file => !partial(file) && file.size === 0);
        const labels = new Map();
        files.filter(file => file.name.endsWith(".crdownload")).forEach(file => labels.set(file, file.name.replace(/\.crdownload$/, "")));
        // QML's JavaScript engine has no Array.flatMap, so the pairs are collected with loops.
        const candidates = [];
        for (const part of parts) {
            for (const placeholder of placeholders)
                candidates.push({
                    part: part,
                    placeholder: placeholder,
                    gap: Math.abs(placeholder.birth - part.birth)
                });
        }
        const pairs = candidates.filter(pair => pair.gap <= sameBirthSeconds).sort((a, b) => a.gap - b.gap);
        const claimed = new Set();
        for (const pair of pairs) {
            if (labels.has(pair.part) || claimed.has(pair.placeholder))
                continue;
            labels.set(pair.part, pair.placeholder.name);
            claimed.add(pair.placeholder);
        }
        return files.filter(partial).map(file => {
            const label = labels.get(file) ?? file.name.replace(/\.part$/, "");
            return {
                label: label,
                trailing: file.size < 1048576 ? "<1 MB" : Math.round(file.size / 1048576) + " MB",
                args: ["file", file.path, label]
            };
        });
    }

    // Calls done with the downloads that are still running, as rows {label, trailing, args} for start(), or fail(reason) when
    // they cannot be listed. Returns the handle of the listing: kill() it when the answer is no longer wanted.
    // A Chrome partial file is named like the download, plus .crdownload. Firefox names a partial file randomly and leaves
    // an empty file with the real name beside it, created within 5 s of it, so a .part file is labelled with that empty
    // file. Each empty file labels one partial file, the nearest in time first. Without one, the label is the partial
    // file's own name.
    function downloads(done, fail): var {
        const argv = ["bash", "-c", `set -euo pipefail
dir=$(xdg-user-dir DOWNLOAD)
printf '%s\\n' "$dir"
find "$dir" -maxdepth 1 -type f \\( -name '*.part' -o -name '*.crdownload' -o -size 0 \\) -print0 |
while IFS= read -r -d '' path; do
  printf '%s' "\${path##*/}"
  stat --printf '/%W\\t%s\\n' -- "$path"
done`];
        return Exec.runOr(argv, stdout => {
            let rows;
            try {
                rows = downloadRows(parseDownloadFiles(stdout));
            } catch (e) {
                console.error("Caffeine: cannot read the list of downloads: " + e);
                fail(String(e));
                return;
            }
            done(rows);
        }, fail);
    }

    // Calls done with the apps that have a window, one row {label, trailing, args} per process. Takes them from the tree
    // the shell already follows, so it answers at once and returns null, which is no handle to kill.
    function apps(done): var {
        const seen = new Set();
        done(Windows.windows.filter(window => !seen.has(window.pid) && seen.add(window.pid)).map(window => {
            const label = Windows.appName(window) || window.name || "unnamed";
            return {
                label: label,
                trailing: String(window.pid),
                args: ["pid", String(window.pid), label]
            };
        }).sort((a, b) => a.label.localeCompare(b.label)));
        return null;
    }

    // While a deadline is set, ticks every minute to update `remaining`, and reads the state again once the deadline has
    // passed, in case the end notice of the command did not arrive.
    Timer {
        interval: 60000
        repeat: true
        running: root.endsAt > 0
        onTriggered: {
            root.now = Date.now();
            if (root.now >= root.endsAt * 1000)
                root.refresh();
        }
    }

    IpcHandler {
        target: "caffeine"

        function refresh(): void {
            root.refresh();
        }
    }

    Component.onCompleted: refresh()
}

import QtQuick
import Quickshell
import Quickshell.Io

// Reloads Sway when its config changes. The config is symlinked into the checkout, so git and the editor change it behind
// Sway's back, and Sway keeps the config it has until it is told to reload. A config that `sway -C` rejects is not loaded: a
// reload would drop every binding the broken edit lost, and the failure is logged, which records it. An editor that writes in
// place truncates the file first and fires another change when the write is done, so a file that is empty is skipped (it is
// logged as information, not as an error): its completion follows. A file cut off in the middle can still pass `sway -C`, which sees only complete lines of
// valid commands, and then the completion reloads it again. The files that the config includes from
// ~/.config/sway/config.d are not watched (TODO.md).
Scope {
    id: root

    readonly property string configPath: Quickshell.env("HOME") + "/.config/sway/config"
    readonly property int validateTimeoutMs: 10000
    readonly property int reloadTimeoutMs: 10000

    // A validation is running, and the config changed again meanwhile: the answer being awaited is about a file that is gone.
    property bool validating: false
    property bool stale: false

    function reloadIfValid(): void {
        if (validating) {
            stale = true;
            return;
        }
        validating = true;
        Exec.runWithin(["sway", "-C", "-c", configPath], validateTimeoutMs, (code, stdout, stderr) => {
            validating = false;
            if (stale) {
                stale = false;
                reloadIfValid();
                return;
            }
            if (code !== 0)
                Exec.failure(["sway", "-C", "-c", configPath], code, "config not reloaded, sway rejects it: " + stderr);
            else
                Exec.runWithin(["swaymsg", "reload"], reloadTimeoutMs, (reloadCode, reloadOut, reloadErr) => {
                    if (reloadCode !== 0)
                        Exec.failure(["swaymsg", "reload"], reloadCode, reloadErr || reloadOut);
                });
        });
    }

    FileView {
        // The file is read again for each change; the load that Quickshell does on its own at start is no change.
        property bool changed: false

        path: root.configPath
        watchChanges: true
        printErrors: false
        onFileChanged: {
            changed = true;
            reload();
        }
        onLoaded: {
            if (!changed)
                return;
            changed = false;
            if (text().trim() === "")
                console.info("SwayConfig: " + root.configPath + " is empty, waiting for the write to finish");
            else
                root.reloadIfValid();
        }
        onLoadFailed: error => console.error("SwayConfig: cannot read " + root.configPath + ":", error)
    }
}

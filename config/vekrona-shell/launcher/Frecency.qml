import QtQuick
import Quickshell
import Quickshell.Io
import "../Vekrona"
import "Ranker.js" as Ranker

// How often and how recently each result was activated: {id: {score, at}} in
// the state directory's launcher-frecency.json. The score halves every seven days; it is
// computed from the stored timestamp whenever it is read (Ranker.js), so nothing ticks.
Scope {
    id: root

    readonly property string path: StateDir.path + "/launcher-frecency.json"
    property var entries: ({})

    function record(id: string): void {
        entries = Ranker.bumped(entries, id, Date.now());
        store.setText(JSON.stringify(entries));
    }

    // Reading text() blocks until the file is loaded, so ranking never sees half-loaded entries.
    Component.onCompleted: {
        try {
            entries = Ranker.parseEntries(store.text());
        } catch (e) {
            console.error("Frecency: " + path + " is unusable, starting empty:", e);
        }
    }

    FileView {
        id: store
        path: root.path
        blockLoading: true
        // A write that dies half way must not leave a file that cannot be parsed: the entries would start empty.
        atomicWrites: true
        printErrors: false
        // A first run has no file yet.
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound)
                console.error("Frecency: cannot read " + root.path + ":", error);
        }
        onSaveFailed: error => console.error("Frecency: cannot write " + root.path + ":", error)
    }
}

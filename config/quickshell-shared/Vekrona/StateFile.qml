import QtQuick
import Quickshell.Io
import "."

// A file that another process writes, followed as it changes: the one place that reads state files. `value` is what `parse`
// made of the text; a file that is missing, unreadable or not what `parse` accepts leaves `absent` there, and all but a
// missing file is logged, so the error pipeline records it.
FileView {
    id: root

    // Turns the text of the file into the value; throws on text that is not valid. JSON by default.
    property var parse: text => JSON.parse(text)
    property var absent: null
    property var value: absent
    // False until the file has been read once, or found missing. (`loaded` is FileView's own signal.)
    property bool settled: false

    // After every read, whether or not the value changed.
    signal refreshed

    // The value goes first: a Pulse takes the first count it is given as the starting one, not as a rise, once `settled` says
    // it is known.
    function settle(next: var): void {
        value = next;
        settled = true;
        refreshed();
    }

    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
        let next;
        try {
            next = parse(text());
        } catch (e) {
            console.error("cannot read " + path + ": " + e);
            next = absent;
        }
        settle(next);
    }
    onLoadFailed: error => {
        if (error !== FileViewError.FileNotFound)
            console.error("cannot read " + path + ": " + error);
        settle(absent);
    }
}

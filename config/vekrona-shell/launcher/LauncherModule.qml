import QtQuick
import ".." as Shell

// The base of every launcher module (modules/*.qml). The host (Launcher.qml) sets `launcher` and
// calls opened, closed, query, fallbacks and view.
//
// A result is {id: "<moduleId>:<key>", title, subtitle?, iconPath?, glyph?, kind, keywords?, aliases?,
// score?, card?: "calc", checked?, actions: [action]}. A result with a `score` (0..1) skips fuzzy matching
// and frecency. The first action runs on Enter, the second on Ctrl+Enter, all are in the Ctrl+K panel.
//
// An action is {id, label, key?, destructive?, confirm?} plus exactly one of exec: [argv], copy: string,
// url: string, push: {title, viewId}, setQuery: string, run: function() (the launcher closes unless it
// returns false). A `destructive` action always needs a confirming second activation: the first one only
// arms the row and shows `confirm`, which defaults to "Press Enter again to <label in lower case>".
Item {
    // The host API: close(), setQuery(text), enterMode(slash), pushView(moduleId, {title, viewId}),
    // toast(text), clearToast(text) (takes the toast back, only while it still shows `text`).
    property var launcher
    property string moduleId
    property string title
    // A Material Symbols name.
    property string glyph
    // The mode keyword: "calc" makes the module reachable as /calc.
    property string slash: ""
    // Contributes to the root search when no mode is active.
    property bool global: true
    // Multiplies the score of every result of this module.
    property real weight: 1.0
    // An always-visible control in the launcher's widget strip.
    property Component widget: null
    // Set by the host: true while this module's mode (/keyword) is the active one, e.g. to evaluate strictly.
    property bool inMode: false

    // Asynchronous delivery of the results for `reqId`: an array. It replaces what the module answered
    // for that request before, so a module may answer at once and deliver a fuller list later.
    signal resultsReady(int reqId, var results)
    // The request `reqId` cannot be answered: the host reports `error` and counts the request as answered.
    signal failed(int reqId, var error)
    // The static results changed; the host queries again.
    signal changed

    // Called on every module each time the launcher opens: refresh state that goes stale while it is closed.
    function opened() {
    }

    // Called on every module each time the launcher closes: stop what only runs while it is open.
    function closed() {
    }

    // The row that tells an asynchronous request failed: "Couldn’t <what>" with the reason below it.
    function errorRow(what: string, reason: string): var {
        return {
            id: moduleId + ":error",
            title: "Couldn’t " + what,
            subtitle: reason,
            glyph: "error",
            kind: "Error",
            score: 1,
            actions: [
                {
                    id: "copy-reason",
                    label: "Copy message",
                    copy: reason
                }
            ]
        };
    }

    // Runs argv, then answers the request `reqId` with toResults(code, stdout, stderr), an array. A toResults
    // that throws fails the request. Returns the Exec.run handle, whose kill() cancels the run.
    function answerFrom(reqId: int, argv: list<string>, toResults): var {
        return Shell.Exec.run(argv, (code, stdout, stderr) => {
            let results;
            try {
                results = toResults(code, stdout, stderr);
            } catch (e) {
                failed(reqId, e);
                return;
            }
            resultsReady(reqId, results);
        });
    }

    // An array, or null when the results arrive later through resultsReady (the host drops stale reqIds).
    function query(text, reqId) {
        return [];
    }

    // Rows for the "Use “text” with" section; only asked in root mode with a non-empty text.
    function fallbacks(text) {
        return [];
    }

    // The results of a pushed sub-view, with the same synchronous or asynchronous rules as query.
    function view(viewId, text, reqId) {
        return [];
    }
}

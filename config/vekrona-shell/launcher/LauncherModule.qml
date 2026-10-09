import QtQuick

// The base of every launcher module (modules/*.qml). The host (Launcher.qml) sets `launcher` and
// calls query, fallbacks and view.
//
// A result is {id: "<moduleId>:<key>", title, subtitle?, iconPath?, glyph?, kind, keywords?, aliases?,
// score?, card?: "calc", checked?, actions: [action]}. A result with a `score` (0..1) skips fuzzy matching
// and frecency. The first action runs on Enter, the second on Ctrl+Enter, all are in the Ctrl+K panel.
//
// An action is {id, label, key?, destructive?, confirm?} plus exactly one of exec: [argv], copy: string,
// url: string, push: {title, viewId}, setQuery: string, run: function() (the launcher closes unless it
// returns false). With `confirm` the first activation only arms the row.
Item {
    // The host API: close(), setQuery(text), enterMode(slash), toast(text).
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

    // Asynchronous delivery of the results for `reqId`.
    signal resultsReady(int reqId, var results)
    // The static results changed; the host queries again.
    signal changed

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

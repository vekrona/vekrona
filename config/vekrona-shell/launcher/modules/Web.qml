import QtQuick
import ".."
import "../.." as Shell

LauncherModule {
    id: root

    // Fewer characters match too much of the profile for the helper to be worth spawning.
    readonly property int minPlacesChars: 2
    readonly property int placesPerKind: 5
    // Places have a frecency score and no text-match score, so they stay below the 0..1 of the application
    // matches: a place scores between its kind's floor and ceiling.
    readonly property var scoreRange: ({
            bookmark: {
                floor: 0.2,
                ceiling: 0.6
            },
            history: {
                floor: 0.1,
                ceiling: 0.4
            }
        })
    readonly property var placeKinds: ({
            bookmark: {
                label: "Bookmark",
                glyph: "bookmark"
            },
            history: {
                label: "History",
                glyph: "history"
            }
        })
    // Resolved once by the helper from the profile's search.json.mozlz4.
    property string engineName: ""
    // The handle of the running places lookup, if any.
    property var current: null

    function searchRow(term: string): var {
        return {
            id: "web:search",
            title: "Search the web for “" + term + "”",
            subtitle: engineName || "Firefox default search engine",
            glyph: "search",
            kind: "Search",
            score: 1,
            actions: [
                {
                    id: "search",
                    label: "Search",
                    exec: ["firefox", "--search", term]
                },
                {
                    id: "copy-text",
                    label: "Copy search text",
                    copy: term
                }
            ]
        };
    }

    function placeRow(place): var {
        const kind = placeKinds[place.kind];
        const range = scoreRange[place.kind];
        return {
            id: "web:" + place.kind + ":" + place.url,
            title: place.title,
            subtitle: place.url,
            glyph: kind.glyph,
            kind: kind.label,
            score: range.floor + place.score * (range.ceiling - range.floor),
            actions: [
                {
                    id: "open",
                    label: "Open",
                    url: place.url
                },
                {
                    id: "copy-url",
                    label: "Copy URL",
                    copy: place.url
                }
            ]
        };
    }

    // One JSON object per line. Only web pages are rows: the launcher opens http and https addresses and nothing else, and
    // Firefox also keeps place: queries, javascript: bookmarklets and file: addresses.
    function parsePlaces(output: string): var {
        return output.split("\n").filter(line => line !== "").map(line => JSON.parse(line)).filter(place => /^https?:\/\//.test(place.url)).map(placeRow);
    }

    function placesRows(argv: list<string>, code: int, stdout: string, stderr: string): var {
        if (code !== 0)
            return [errorRow("search bookmarks and history", Shell.Exec.failure(argv, code, stderr))];
        try {
            return parsePlaces(stdout);
        } catch (e) {
            console.error("web: cannot read the output of " + JSON.stringify(argv) + ": " + e);
            return [errorRow("read bookmarks and history", String(e))];
        }
    }

    function cancel(): void {
        if (current)
            current.kill();
        current = null;
    }

    // In /search the search row comes first and is answered at once, so Enter never waits for the places;
    // in the root search it is only a fallback. The places follow through a second delivery that
    // repeats the head.
    function query(text: string, reqId: int): var {
        cancel();
        const term = text.trim();
        if (term === "")
            return [];
        const head = inMode ? [searchRow(term)] : [];
        if (term.length < minPlacesChars)
            return head;
        // "--" ends the options, so a term like "-v" is a term.
        const argv = ["vekrona-firefox", "places", "--limit", String(placesPerKind), "--", term];
        current = answerFrom(reqId, argv, (code, stdout, stderr) => head.concat(placesRows(argv, code, stdout, stderr)));
        return head.length > 0 ? head : null;
    }

    function fallbacks(text: string): var {
        const term = text.trim();
        return term === "" ? [] : [searchRow(term)];
    }

    Component.onCompleted: {
        Shell.Exec.runChecked(["vekrona-firefox", "engine-name"], stdout => root.engineName = stdout.trim());
    }
    onEngineNameChanged: changed()

    moduleId: "web"
    title: "Search"
    glyph: "travel_explore"
    slash: "search"
    weight: 0.8
}

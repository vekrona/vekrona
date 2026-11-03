pragma Singleton
import QtQuick
import Quickshell
import Quickshell.I3

// Sway's windows, which workspaces hold one, and which window takes the focus: the one reader of the sway tree and of its window
// events, for every widget that wants them. The tree is read again only when an event changes what it holds (a window or workspace
// appears, goes or moves), not for every title or focus change, which fire all the time. An event that arrives while a read runs
// may be newer than the answer, so the window set comes from a read that SwayQuery runs once more after it, and the focus of such
// an answer is not reported.
Singleton {
    id: root

    // The `change` of the window and workspace events that alter a window or a workspace of the tree. A change in a title, focus,
    // urgency, mark, fullscreen mode or floating state alters none of them.
    readonly property var treeChanges: ["new", "close", "move", "init", "empty", "rename"]
    // The windows of the tree, leaves only: Sway containers that hold an app. Empty while the tree is unknown.
    property var windows: []
    // The numbers of the workspaces that hold a window.
    property var occupiedNumbers: []
    // A focus event arrived while the tree was being read, so the focused window of that answer may be older than the event.
    property bool focusMovedDuringRead: false

    // The window with the Sway container id `id` took the focus. Reported for every focus event, and for the focused window of a
    // tree read, which catches up on focus changes whose events were lost.
    signal focused(int id)
    // The window with the Sway container id `id` closed. A window that closes while events are lost is not reported; it only
    // drops out of `windows` at the next read.
    signal closed(int id)

    // The windows of the tree, leaves only: Sway containers that hold an app.
    function leaves(node): var {
        const found = [];
        function walk(n) {
            const children = (n.nodes || []).concat(n.floating_nodes || []);
            if (n.pid != null && children.length === 0)
                found.push(n);
            children.forEach(walk);
        }
        walk(node);
        return found;
    }

    function occupiedWorkspaces(node): var {
        const occupied = [];
        function walk(n) {
            if (n.type === "workspace" && typeof n.num === "number" && n.num !== -1) {
                const hasContent = (n.nodes && n.nodes.length > 0) || (n.floating_nodes && n.floating_nodes.length > 0);
                if (hasContent)
                    occupied.push(n.num);
            }
            (n.nodes || []).concat(n.floating_nodes || []).forEach(walk);
        }
        walk(node);
        return occupied;
    }

    // What an app calls its windows: the Wayland app_id, else the X11 class.
    function appName(window): string {
        return window.app_id || window.window_properties?.class || "";
    }

    // Focuses a window of the first app in `names` that has one, switching to its workspace. A name
    // matches an app name ignoring case. When no name has a window, nothing happens: the app may have closed it.
    function focusApp(names: list<string>): void {
        const wanted = names.filter(name => name !== "").map(name => name.toLowerCase());
        for (const name of wanted) {
            const window = windows.find(candidate => appName(candidate).toLowerCase() === name);
            if (window) {
                I3.dispatch(`[con_id=${window.id}] focus`);
                return;
            }
        }
    }

    // Reads an event of the window or workspace subscription: reports a window's focus or close, and reads the tree again when the
    // event alters it.
    function follow(event): void {
        let e;
        try {
            e = JSON.parse(event.data);
        } catch (error) {
            console.error("Windows: a sway " + event.type + " event is not valid JSON: " + error);
            query.run();
            return;
        }
        if (event.type === "window" && e.change === "focus") {
            if (query.querying)
                focusMovedDuringRead = true;
            focused(e.container.id);
        } else if (event.type === "window" && e.change === "close") {
            closed(e.container.id);
        }
        if (treeChanges.includes(e.change))
            query.run();
    }

    SwayQuery {
        id: query
        argv: ["swaymsg", "-t", "get_tree"]
        onParsed: json => {
            root.windows = root.leaves(json);
            root.occupiedNumbers = root.occupiedWorkspaces(json);
            const current = root.windows.find(window => window.focused);
            if (current && !root.focusMovedDuringRead)
                root.focused(current.id);
            root.focusMovedDuringRead = false;
        }
        // What the widgets show from the last answer is no longer known; the failure itself has been logged. The next read starts
        // after every event seen so far, so its focus is current.
        onUnavailable: {
            root.windows = [];
            root.occupiedNumbers = [];
            root.focusMovedDuringRead = false;
        }
    }

    I3IpcListener {
        subscriptions: ["window", "workspace"]
        onIpcEvent: event => root.follow(event)
    }
}

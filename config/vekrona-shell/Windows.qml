pragma Singleton
import QtQuick
import Quickshell
import Quickshell.I3

// Sway's windows and which workspaces hold one: the one reader of the sway tree, for every widget that wants it. The tree
// is read again only when an event changes what it holds (a window or workspace appears, goes or moves), not for every title
// or focus change, which fire all the time.
Singleton {
    id: root

    // The `change` of the window and workspace events that alter a window or a workspace of the tree. A change in a title, focus,
    // urgency, mark, fullscreen mode or floating state alters none of them.
    readonly property var treeChanges: ["new", "close", "move", "init", "empty", "rename"]
    // The windows of the tree, leaves only: Sway containers that hold an app. Empty while the tree is unknown.
    property var windows: []
    // The numbers of the workspaces that hold a window.
    property var occupiedNumbers: []

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

    // Whether an event of the window or workspace subscription alters the tree.
    function altersTree(event): bool {
        let change;
        try {
            change = JSON.parse(event.data).change;
        } catch (e) {
            console.error("Windows: a sway " + event.type + " event is not valid JSON: " + e);
            return true;
        }
        return treeChanges.includes(change);
    }

    SwayQuery {
        id: query
        argv: ["swaymsg", "-t", "get_tree"]
        onParsed: json => {
            root.windows = root.leaves(json);
            root.occupiedNumbers = root.occupiedWorkspaces(json);
        }
        // What the widgets show from the last answer is no longer known; the failure itself has been logged.
        onUnavailable: {
            root.windows = [];
            root.occupiedNumbers = [];
        }
    }

    I3IpcListener {
        subscriptions: ["window", "workspace"]
        onIpcEvent: event => {
            if (root.altersTree(event))
                query.run();
        }
    }
}

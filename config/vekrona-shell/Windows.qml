pragma Singleton
import QtQuick
import Quickshell
import Quickshell.I3

Singleton {
    id: root

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

    // Focuses a window of the first app in `names` that has one, switching to its workspace. A name
    // matches a Wayland app_id or an X11 class, ignoring case. When no name has a window, nothing
    // happens: the app may have closed it.
    function focusApp(names: list<string>): void {
        const wanted = names.filter(name => name !== "").map(name => name.toLowerCase());
        if (wanted.length === 0)
            return;
        Exec.run(["swaymsg", "-t", "get_tree"], (code, stdout, stderr) => {
            if (code !== 0) {
                Exec.failure(["swaymsg", "-t", "get_tree"], code, stderr);
                return;
            }
            const windows = leaves(JSON.parse(stdout));
            for (const name of wanted) {
                const window = windows.find(w => (w.app_id || w.window_properties?.class || "").toLowerCase() === name);
                if (window) {
                    I3.dispatch(`[con_id=${window.id}] focus`);
                    return;
                }
            }
        });
    }
}

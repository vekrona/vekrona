// Resident Cmd+Tab app switcher: a row of app icons in most-recently-used order,
// started once per session by vekrona-app-switch.service and hidden until Sway's
// Super+Tab bindings send `appswitch next|prev` over IPC. The first call opens
// it, later ones step the selection. It commits (focuses the app) when Super
// goes up, Return or a click picks, Escape cancels. It keeps its list of
// windows and their recency from Sway's window events, so opening it needs no
// query. It reads its colors and metrics from the design's tokens.json (linked
// next to this file) and follows the desktop's dark/light mode live.
import QtQuick
import Quickshell
import Quickshell.I3
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // Sway container id -> {id, app, stamp}; `stamp` says when it was last focused.
    property var windows: ({})
    property int clock: 0
    property var items: []
    property int selected: 0
    property bool shown: false

    // ---- Design tokens: tokens.json, the Vekrona Design System (config/tokens.json, linked next to
    // this file). Every lookup is a call of token or typeStyle with a quoted name; tests/stages/
    // test-app-switch-tokens.sh holds those names to the ones tokens.json defines.
    // The switcher must still work without tokens, so anything unreadable or missing falls back to
    // the monochrome set below, the only literals in this file.
    readonly property var fallbacks: ({
            "scrim": "black",
            "surface-1": "black",
            "line": "white",
            "ink": "white",
            "ink-muted": "white",
            "accent": "white",
            "space-2": 8,
            "space-4": 16,
            "size-icon-xl": 72,
            "border-hair": 1,
            "border-indicator": 2,
            "opacity-scrim": 0.6
        })
    readonly property var fallbackStyle: ({
            family: "sans-serif",
            size: 13,
            line: 18,
            weight: 600,
            tracking: 0
        })

    // The parsed tokens.json, null when it cannot be loaded (tokenView.onLoadFailed said why).
    // Reading text() blocks until the first load; the binding re-runs on every reload.
    readonly property var tokens: {
        const raw = tokenView.text();
        if (raw === "")
            return null;
        try {
            return JSON.parse(raw);
        } catch (e) {
            console.error("vekrona-app-switch: tokens.json is not valid JSON:", e);
            return null;
        }
    }

    // $XDG_STATE_HOME/vekrona/theme holds the desktop's mode, `dark` or `light`.
    readonly property string mode: {
        const raw = modeView.text().trim();
        if (raw === "light" || raw === "dark")
            return raw;
        // An empty text means the load failed, which modeView.onLoadFailed said.
        if (raw !== "")
            console.error("vekrona-app-switch: theme file holds '" + raw + "', not dark or light; using dark");
        return "dark";
    }

    FileView {
        id: tokenView
        path: Quickshell.shellPath("tokens.json")
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
        onLoadFailed: error => console.error("vekrona-app-switch: cannot read tokens.json:", error)
    }

    FileView {
        id: modeView
        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/vekrona/theme"
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
        onLoadFailed: error => console.error("vekrona-app-switch: cannot read the theme mode file:", error)
    }

    // The named token's value: a color for the current mode, or a number for spacing, border, size and opacity.
    function resolve(name) {
        const color = tokens.color.tokens.find(t => t.name === name);
        if (color)
            return color.value[mode];
        for (const group of ["spacing", "border", "size", "opacity"]) {
            const found = tokens[group].tokens.find(t => t.name === name);
            if (found)
                return parseFloat(found.value);
        }
        throw new Error("no token " + name);
    }

    function token(name) {
        if (tokens === null)
            return fallbacks[name];
        try {
            const value = resolve(name);
            if (value === undefined || (typeof value === "number" && isNaN(value)))
                throw new Error("no usable value for mode " + mode);
            return value;
        } catch (e) {
            console.error("vekrona-app-switch: token", name, "unusable:", e);
            return fallbacks[name];
        }
    }

    // A type style as {family, size, line, weight, tracking}; tracking is in em.
    function typeStyle(name) {
        if (tokens === null)
            return fallbackStyle;
        try {
            for (const group of tokens.type.groups) {
                const style = group.styles.find(s => s.name === name);
                if (!style)
                    continue;
                const family = tokens.type.families[group.family].split(",")[0].trim().replace(/^["']|["']$/g, "");
                const result = {
                    family: family,
                    size: parseFloat(style.fontSize),
                    line: parseFloat(style.lineHeight),
                    weight: style.fontWeight,
                    tracking: style.letterSpacing ? parseFloat(style.letterSpacing) : 0
                };
                if (family === "" || isNaN(result.size) || isNaN(result.line) || isNaN(result.tracking) || typeof result.weight !== "number")
                    throw new Error("unusable style " + JSON.stringify(style));
                return result;
            }
            throw new Error("no type style " + name);
        } catch (e) {
            console.error("vekrona-app-switch: type style", name, "unusable:", e);
            return fallbackStyle;
        }
    }

    readonly property var labelStyle: typeStyle("label")
    readonly property real space2: token("space-2")
    readonly property real space4: token("space-4")
    readonly property real iconXl: token("size-icon-xl")
    readonly property real borderIndicator: token("border-indicator")

    function track(node) {
        const known = windows[node.id];
        windows[node.id] = {
            id: node.id,
            app: node.app_id || node.window_properties?.class || "?",
            stamp: known ? known.stamp : 0
        };
    }

    function focused(id) {
        windows[id].stamp = ++clock;
    }

    function trackTree(node) {
        const children = (node.nodes || []).concat(node.floating_nodes || []);
        if (node.pid != null && children.length === 0) {
            track(node);
            if (node.focused)
                focused(node.id);
        }
        children.forEach(trackTree);
    }

    // Windows that exist before the first event arrives.
    Process {
        command: ["swaymsg", "-t", "get_tree"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root.trackTree(JSON.parse(text))
        }
        onExited: code => {
            if (code !== 0)
                console.error("swaymsg -t get_tree exited with status " + code);
        }
    }

    I3IpcListener {
        subscriptions: ["window"]
        onIpcEvent: event => {
            const e = JSON.parse(event.data);
            if (e.change === "new") {
                root.track(e.container);
            } else if (e.change === "close") {
                delete root.windows[e.container.id];
            } else if (e.change === "focus") {
                root.track(e.container);
                root.focused(e.container.id);
            }
        }
    }

    // The most recently focused window of each app, most recent first.
    function recentApps() {
        const seen = new Set();
        return Object.values(windows).sort((a, b) => b.stamp - a.stamp).filter(w => !seen.has(w.app) && seen.add(w.app));
    }

    function step(dir) {
        if (!shown) {
            const apps = recentApps();
            if (apps.length < 2)
                return;
            items = apps;
            selected = dir > 0 ? 1 : apps.length - 1;
            shown = true;
            superWatch.running = true;
        } else {
            selected = (selected + dir + items.length) % items.length;
        }
    }

    function finish(commit) {
        if (!shown)
            return;
        shown = false;
        superWatch.running = false;
        if (commit)
            I3.dispatch("[con_id=" + items[selected].id + "] focus");
    }

    // Neither Sway nor Qt sees Super go up reliably, so the helper watches the
    // kernel's key state and exits once no Super key is down.
    Process {
        id: superWatch
        command: ["python3", Quickshell.shellPath("wait-super-release.py")]
        onExited: code => {
            if (code !== 0)
                console.error("wait-super-release.py exited with status " + code);
            root.finish(true);
        }
    }

    IpcHandler {
        target: "appswitch"
        function next(): void { root.step(1); }
        function prev(): void { root.step(-1); }
        function commit(): void { root.finish(true); }
        function cancel(): void { root.finish(false); }
    }

    // Desktop entries load asynchronously; reading this list makes the icon
    // and name bindings re-run once they arrive.
    readonly property var entries: DesktopEntries.applications.values

    function entryFor(app) {
        return entries.length >= 0 ? (DesktopEntries.byId(app) || DesktopEntries.heuristicLookup(app)) : null;
    }

    function iconFor(app) {
        return Quickshell.iconPath(entryFor(app)?.icon || app, "application-x-executable");
    }

    function nameFor(app) {
        return entryFor(app)?.name || app;
    }

    PanelWindow {
        visible: root.shown
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; bottom: true; left: true; right: true }
        // Only the panel takes pointer input; clicks on the scrim reach the windows below, as before.
        mask: Region { item: panel }
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "vekrona-app-switch"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        Rectangle {
            anchors.fill: parent
            color: Qt.alpha(root.token("scrim"), root.token("opacity-scrim"))
        }

        Item {
            id: keys
            anchors.fill: parent
            focus: true

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape)
                    root.finish(false);
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                    root.finish(true);
                else if (event.key === Qt.Key_Right)
                    root.step(1);
                else if (event.key === Qt.Key_Left)
                    root.step(-1);
            }
        }

        Rectangle {
            id: panel
            anchors.centerIn: parent
            width: row.width + 2 * root.space4
            height: row.height + 2 * root.space4
            radius: 0
            color: root.token("surface-1")
            border.color: root.token("line")
            border.width: root.token("border-hair")

            Row {
                id: row
                anchors.centerIn: parent
                spacing: root.space2

                Repeater {
                    model: root.items

                    Item {
                        id: tile
                        required property var modelData
                        required property int index
                        readonly property bool current: index === root.selected

                        width: root.iconXl + 2 * root.space4
                        height: root.space2 + root.iconXl + root.space2
                            + root.labelStyle.line + root.borderIndicator + root.space2

                        Image {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: root.space2
                            width: root.iconXl
                            height: root.iconXl
                            sourceSize: Qt.size(2 * root.iconXl, 2 * root.iconXl)
                            source: root.iconFor(tile.modelData.app)
                            smooth: true
                        }

                        Text {
                            id: label
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: root.space2 + root.iconXl + root.space2
                            width: parent.width - 2 * root.space2
                            height: root.labelStyle.line
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            text: root.nameFor(tile.modelData.app)
                            color: tile.current ? root.token("ink") : root.token("ink-muted")
                            font.family: root.labelStyle.family
                            font.pixelSize: root.labelStyle.size
                            font.weight: root.labelStyle.weight
                            font.letterSpacing: root.labelStyle.tracking * root.labelStyle.size
                        }

                        Rectangle {
                            visible: tile.current
                            anchors.horizontalCenter: label.horizontalCenter
                            y: label.y + label.height
                            width: Math.min(label.contentWidth, label.width)
                            height: root.borderIndicator
                            color: root.token("accent")
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                root.selected = tile.index;
                                root.finish(true);
                            }
                        }
                    }
                }
            }
        }
    }
}

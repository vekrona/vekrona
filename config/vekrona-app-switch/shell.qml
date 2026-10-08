// Resident Cmd+Tab app switcher: a row of app icons in most-recently-used order,
// started once per session by vekrona-app-switch.service and hidden until Sway's
// Super+Tab bindings send `appswitch next|prev` over IPC. The first call opens
// it, later ones step the selection. It commits (focuses the app) when Super
// goes up, Return or a click picks, Escape cancels. It keeps its list of
// windows and their recency from Sway's window events, so opening it needs no
// query.
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
        implicitWidth: panel.width
        implicitHeight: panel.height
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "vekrona-app-switch"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

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
            width: row.width + 32
            height: row.height + 32
            radius: 22
            color: Qt.rgba(0.1, 0.1, 0.12, 0.88)
            border.color: Qt.rgba(1, 1, 1, 0.12)
            border.width: 1

            Row {
                id: row
                anchors.centerIn: parent
                spacing: 8

                Repeater {
                    model: root.items

                    Rectangle {
                        required property var modelData
                        required property int index
                        readonly property bool current: index === root.selected

                        width: 104
                        height: 120
                        radius: 16
                        color: current ? Qt.rgba(1, 1, 1, 0.16) : "transparent"

                        Image {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 12
                            width: 72
                            height: 72
                            sourceSize: Qt.size(144, 144)
                            source: root.iconFor(modelData.app)
                            smooth: true
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 10
                            width: parent.width - 12
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: root.nameFor(modelData.app)
                            color: "white"
                            opacity: current ? 1 : 0.6
                            font.pixelSize: 12
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                root.selected = index;
                                root.finish(true);
                            }
                        }
                    }
                }
            }
        }
    }
}

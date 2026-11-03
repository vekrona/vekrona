import QtQuick
import Quickshell
import Quickshell.I3
import Quickshell.Io
import Quickshell.Wayland
import "Vekrona"
import "."

// The Cmd+Tab app switcher: a row of app icons in most-recently-used order, hidden until Sway's Super+Tab bindings send
// `appswitch next|prev` over IPC. The first call opens it, later ones step the selection. It commits (focuses the app) when Super
// goes up, Return or a click picks, Escape cancels. It lists the windows Windows has read from Sway's tree and orders them by
// the focus changes Windows reports, so opening it needs no query.
PanelWindow {
    id: root

    // Sway container id -> when that window was last focused, as a count that grows with every focus change.
    property var stamps: ({})
    property int clock: 0
    property var items: []
    property int selected: 0
    property bool shown: false
    readonly property var labelStyle: VekronaTheme.type.label
    // The space between the panel's edge and its tiles, and between a tile's edge and its icon.
    readonly property int padding: VekronaTheme.space4
    // Where a tile's label starts: below the icon and the gaps above and below it.
    readonly property int labelTop: VekronaTheme.space2 + VekronaTheme.iconXl + VekronaTheme.space2
    // Icons are rasterised at twice their size, so they stay sharp on a display scaled up to 2.
    readonly property size iconRaster: Qt.size(2 * VekronaTheme.iconXl, 2 * VekronaTheme.iconXl)

    // A start, restart or hot reload while the switcher was open would leave Sway in the appswitch mode.
    Component.onCompleted: I3.dispatch("mode default")

    // The most recently focused window of each app, most recent first; a window never seen focused comes last.
    function recentApps(): var {
        const seen = new Set();
        return Windows.windows.map(window => ({
                    id: window.id,
                    app: Windows.appName(window) || "?",
                    stamp: stamps[window.id] ?? 0
                })).sort((a, b) => b.stamp - a.stamp).filter(w => !seen.has(w.app) && seen.add(w.app));
    }

    function step(dir: int): void {
        if (shown) {
            selected = (selected + dir + items.length) % items.length;
            return;
        }
        const apps = recentApps();
        if (apps.length < 2)
            return;
        items = apps;
        selected = dir > 0 ? 1 : apps.length - 1;
        KeyboardSurface.claim(root);
        shown = true;
        I3.dispatch("mode appswitch");
    }

    function finish(commit: bool): void {
        if (!shown)
            return;
        shown = false;
        I3.dispatch("mode default");
        if (commit)
            I3.dispatch("[con_id=" + items[selected].id + "] focus");
    }

    // Desktop entries load asynchronously; reading this list makes the icon and name bindings re-run once they arrive.
    readonly property var entries: DesktopEntries.applications.values

    function entryFor(app: string): var {
        return entries.length >= 0 ? (DesktopEntries.byId(app) || DesktopEntries.heuristicLookup(app)) : null;
    }

    function iconFor(app: string): string {
        return Quickshell.iconPath(entryFor(app)?.icon || app, "application-x-executable");
    }

    function nameFor(app: string): string {
        return entryFor(app)?.name || app;
    }

    visible: shown
    // The window is the panel and nothing else: opaque, and centred by the compositor because it has no anchors.
    color: VekronaTheme.c.surface1
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: row.width + 2 * root.padding
    implicitHeight: row.height + 2 * root.padding
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "vekrona-app-switch"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Connections {
        target: Windows
        function onFocused(id: int): void {
            root.stamps[id] = ++root.clock;
        }
        function onClosed(id: int): void {
            delete root.stamps[id];
        }
    }

    // Exists only while the switcher is open, which is also when Super is being waited for.
    Loader {
        active: root.shown
        sourceComponent: SuperKeys {
            onReleased: root.finish(true)
        }
    }

    IpcHandler {
        target: "appswitch"
        function next(): void { root.step(1); }
        function prev(): void { root.step(-1); }
        function commit(): void { root.finish(true); }
        function cancel(): void { root.finish(false); }
        // The apps the switcher would list, most recent first, as JSON for tests.
        function apps(): string { return JSON.stringify(root.recentApps().map(w => w.app)); }
    }

    Item {
        anchors.fill: parent
        focus: true

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape)
                root.finish(false);
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                root.finish(true);
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.color: VekronaTheme.c.line
        border.width: VekronaTheme.borderHair

        Row {
            id: row
            anchors.centerIn: parent
            spacing: VekronaTheme.space2

            Repeater {
                model: root.items

                Item {
                    id: tile
                    required property var modelData
                    required property int index
                    readonly property bool current: index === root.selected

                    width: VekronaTheme.iconXl + 2 * root.padding
                    height: root.labelTop + root.labelStyle.line + VekronaTheme.space2

                    Rectangle {
                        anchors.fill: parent
                        visible: tile.current
                        color: VekronaTheme.c.selected
                    }

                    Image {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: VekronaTheme.space2
                        width: VekronaTheme.iconXl
                        height: VekronaTheme.iconXl
                        sourceSize: root.iconRaster
                        source: root.iconFor(tile.modelData.app)
                        smooth: true
                    }

                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: root.labelTop
                        width: parent.width - 2 * VekronaTheme.space2
                        height: root.labelStyle.line
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                        style: root.labelStyle
                        text: root.nameFor(tile.modelData.app)
                        color: tile.current ? VekronaTheme.c.ink : VekronaTheme.c.inkMuted
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

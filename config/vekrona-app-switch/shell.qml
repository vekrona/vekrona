// Overlay for bin/vekrona-app-switch: a row of app icons in most-recently-used
// order. Sway's Super+Tab bindings step the selection over IPC, and
// bin/vekrona-app-switch commits it over IPC once Super is released; Return
// also commits, Escape cancels.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property var items: JSON.parse(Quickshell.env("VEKRONA_SWITCH_ITEMS") || "[]")
    property int selected: Math.max(0, Math.min(items.length - 1, parseInt(Quickshell.env("VEKRONA_SWITCH_START") || "0")))
    property bool done: false

    function step(dir) {
        if (items.length > 0)
            selected = (selected + dir + items.length) % items.length;
    }

    function finish(commit) {
        if (done)
            return;
        done = true;
        if (commit && items.length > 0) {
            focuser.command = ["swaymsg", "[con_id=" + items[selected].id + "] focus"];
            focuser.running = true;
        } else {
            Qt.quit();
        }
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

    Process {
        id: focuser
        onExited: Qt.quit()
    }

    IpcHandler {
        target: "appswitch"
        function next(): void { root.step(1); }
        function prev(): void { root.step(-1); }
        function commit(): void { root.finish(true); }
        function cancel(): void { root.finish(false); }
    }

    PanelWindow {
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

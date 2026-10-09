import QtQuick
import Quickshell.Io
import ".."
import "../.." as Shell
import "../../Vekrona"

LauncherModule {
    id: root

    // The update check's state file, written by root. It is missing until the first check has run.
    property string updatesPath: "/var/lib/vekrona/updates.json"
    property bool updatesPending: false

    readonly property var updateCommands: [
        {
            id: "update-restart",
            title: "Update and restart",
            subtitle: "Install the pending updates, then restart the computer",
            glyph: "system_update",
            command: ["vekrona-update-start", "vekrona-update-reboot.service"],
            aliases: ["update and reboot"],
            armVerb: "update and restart"
        },
        {
            id: "update-shutdown",
            title: "Update and shut down",
            subtitle: "Install the pending updates, then power off the computer",
            glyph: "upgrade",
            command: ["vekrona-update-start", "vekrona-update-poweroff.service"],
            aliases: ["update and power off", "update and poweroff"],
            armVerb: "update and shut down"
        }
    ]

    readonly property var baseCommands: [
        {
            id: "lock",
            title: "Lock",
            subtitle: "Lock the screen",
            glyph: "lock",
            command: ["vekrona-lock"],
            aliases: [],
            armVerb: ""
        },
        {
            id: "sleep",
            title: "Sleep",
            subtitle: "Suspend the computer to memory",
            glyph: "bedtime",
            command: ["systemctl", "suspend"],
            aliases: ["suspend", "sleep"],
            armVerb: ""
        },
        {
            id: "logout",
            title: "Log out",
            subtitle: "End the session",
            glyph: "logout",
            command: ["swaymsg", "exit"],
            aliases: ["logout", "logoff", "sign out", "exit"],
            armVerb: "log out"
        },
        {
            id: "restart",
            title: "Restart",
            subtitle: "Restart the computer",
            glyph: "restart_alt",
            command: ["systemctl", "reboot"],
            aliases: ["reboot", "restart"],
            armVerb: "restart"
        },
        {
            id: "shutdown",
            title: "Shut down",
            subtitle: "Power off the computer",
            glyph: "power_settings_new",
            command: ["systemctl", "poweroff"],
            aliases: ["shutdown", "poweroff", "power off", "halt"],
            armVerb: "shut down"
        }
    ]

    // armVerb is set for the commands that need a second press: "Press Enter again to <armVerb>".
    // The update commands sit right before Restart while updates are pending.
    readonly property var commands: {
        const all = baseCommands.slice();
        if (updatesPending)
            all.splice(all.findIndex(command => command.id === "restart"), 0, ...updateCommands);
        return all;
    }

    function readUpdates(text: string): void {
        try {
            updatesPending = JSON.parse(text).pending === true;
        } catch (e) {
            updatesPending = false;
            console.error("Power: cannot read the update state " + updatesPath + ":", e);
        }
    }

    function opened() {
        updates.reload();
    }

    function row(item): var {
        const action = {
            id: item.id,
            label: item.title,
            exec: item.command
        };
        if (item.armVerb !== "")
            action.destructive = true;
        return {
            id: "power:" + item.id,
            title: item.title,
            subtitle: item.subtitle,
            glyph: item.glyph,
            kind: "Command",
            aliases: item.aliases,
            actions: [action]
        };
    }

    function query(text: string, reqId: int): var {
        return commands.map(row);
    }

    moduleId: "power"
    title: "Power"
    glyph: "power_settings_new"
    slash: "power"

    onCommandsChanged: changed()

    FileView {
        id: updates
        path: root.updatesPath
        watchChanges: true
        onLoaded: root.readUpdates(text())
        onLoadFailed: error => {
            root.updatesPending = false;
            if (error !== FileViewError.FileNotFound)
                console.error("Power: cannot read " + root.updatesPath + ":", error);
        }
        onFileChanged: reload()
    }

    // One keyboard stop: Left/Right move `current`, Enter/Space press it. A command with an
    // armVerb arms on the first press and runs on the second.
    widget: Component {
        Item {
            id: strip

            property var launcher
            property var module: root
            property int current: 0
            property int armed: -1
            // The toast shown for the armed command, which disarming takes back (and no other toast).
            property string armedToast: ""
            property int hovered: -1
            readonly property int labelled: armed >= 0 ? armed : hovered >= 0 ? hovered : activeFocus ? current : -1

            function pressAgain(item): string {
                return "Press again to " + item.armVerb;
            }

            function press(index: int): void {
                const item = module.commands[index];
                if (item.armVerb !== "" && armed !== index) {
                    armed = index;
                    armedToast = pressAgain(item);
                    launcher.toast(armedToast);
                    return;
                }
                armed = -1;
                Shell.Exec.detached(item.command);
                launcher.close();
            }

            implicitWidth: buttons.width
            implicitHeight: VekronaTheme.sizeTarget + VekronaTheme.space1 + caption.height

            Accessible.role: Accessible.ToolBar
            Accessible.name: "Power"

            Keys.onLeftPressed: current = Math.max(0, current - 1)
            Keys.onRightPressed: current = Math.min(module.commands.length - 1, current + 1)
            Keys.onReturnPressed: press(current)
            Keys.onEnterPressed: press(current)
            Keys.onSpacePressed: press(current)
            // Leaves the key to the host, which hands focus back to the search field.
            Keys.onEscapePressed: event => {
                armed = -1;
                event.accepted = false;
            }
            onCurrentChanged: armed = -1
            // Pending updates add or remove buttons, which moves every index after them.
            Connections {
                target: strip.module
                function onCommandsChanged() {
                    strip.armed = -1;
                    strip.current = Math.min(strip.current, strip.module.commands.length - 1);
                }
            }
            // Disarming (any way) takes the "Press again" toast back, unless another toast replaced it.
            onArmedChanged: {
                if (armed < 0) {
                    launcher.clearToast(armedToast);
                    armedToast = "";
                }
            }
            onActiveFocusChanged: {
                if (!activeFocus)
                    armed = -1;
            }

            Row {
                id: buttons
                spacing: VekronaTheme.space2

                Repeater {
                    model: strip.module.commands

                    delegate: Item {
                        id: button

                        required property int index
                        required property var modelData
                        readonly property bool armed: strip.armed === index

                        width: VekronaTheme.sizeTarget
                        height: VekronaTheme.sizeTarget

                        Accessible.role: Accessible.Button
                        Accessible.name: armed ? strip.pressAgain(modelData) : modelData.title

                        Rectangle {
                            anchors.fill: parent
                            color: mouse.pressed ? VekronaTheme.c.surface3
                                 : mouse.containsMouse ? VekronaTheme.c.surface2 : "transparent"
                        }

                        Pictogram {
                            anchors.centerIn: parent
                            name: button.modelData.glyph
                            color: button.armed ? VekronaTheme.c.dangerInk : VekronaTheme.c.ink
                        }

                        FocusRing {
                            shown: button.armed || (strip.activeFocus && strip.current === button.index)
                            outer: button.armed ? VekronaTheme.c.dangerInk : VekronaTheme.c.focus
                            inner: button.armed ? VekronaTheme.c.dangerInk : VekronaTheme.c.focusInner
                        }

                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: strip.hovered = button.index
                            onExited: {
                                if (strip.hovered === button.index)
                                    strip.hovered = -1;
                            }
                            onClicked: {
                                strip.current = button.index;
                                strip.forceActiveFocus();
                                strip.press(button.index);
                            }
                        }
                    }
                }
            }

            Label {
                id: caption
                anchors.top: buttons.bottom
                anchors.topMargin: VekronaTheme.space1
                height: VekronaTheme.type.caption.line
                style: VekronaTheme.type.caption
                color: strip.armed >= 0 ? VekronaTheme.c.dangerInk : VekronaTheme.c.ink
                text: strip.labelled < 0 ? ""
                    : strip.armed >= 0 ? strip.pressAgain(strip.module.commands[strip.armed])
                    : strip.module.commands[strip.labelled].title
            }
        }
    }
}

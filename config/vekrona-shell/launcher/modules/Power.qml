import QtQuick
import "../../Vekrona"
import ".."

LauncherModule {
    id: root

    // The update check's state file, written by root. It is missing until the first check has run.
    property string updatesPath: "/var/lib/vekrona/updates.json"
    readonly property bool updatesPending: updates.value

    readonly property var updateCommands: [
        {
            id: "update-restart",
            title: "Update and restart",
            subtitle: "Install the pending updates, then restart the computer",
            glyph: "system_update",
            command: ["vekrona-update-start", "vekrona-update-reboot.service"],
            aliases: ["update and reboot"],
            destructive: true
        },
        {
            id: "update-shutdown",
            title: "Update and shut down",
            subtitle: "Install the pending updates, then power off the computer",
            glyph: "upgrade",
            command: ["vekrona-update-start", "vekrona-update-poweroff.service"],
            aliases: ["update and power off", "update and poweroff"],
            destructive: true
        }
    ]

    readonly property var baseCommands: [
        {
            id: "lock",
            title: "Lock",
            subtitle: "Lock the screen",
            glyph: "lock",
            command: ["vekrona-lock", "start"],
            aliases: [],
            destructive: false
        },
        {
            id: "sleep",
            title: "Sleep",
            subtitle: "Suspend the computer to memory",
            glyph: "bedtime",
            command: ["vekrona-suspend", "now"],
            aliases: ["suspend", "sleep"],
            destructive: false
        },
        {
            id: "logout",
            title: "Log out",
            subtitle: "End the session",
            glyph: "logout",
            command: ["swaymsg", "exit"],
            aliases: ["logout", "logoff", "sign out", "exit"],
            destructive: true
        },
        {
            id: "restart",
            title: "Restart",
            subtitle: "Restart the computer",
            glyph: "restart_alt",
            command: ["systemctl", "reboot"],
            aliases: ["reboot", "restart"],
            destructive: true
        },
        {
            id: "shutdown",
            title: "Shut down",
            subtitle: "Power off the computer",
            glyph: "power_settings_new",
            command: ["systemctl", "poweroff"],
            aliases: ["shutdown", "poweroff", "power off", "halt"],
            destructive: true
        }
    ]

    // The update commands sit right before Restart while updates are pending.
    readonly property var commands: {
        const all = baseCommands.slice();
        if (updatesPending)
            all.splice(all.findIndex(command => command.id === "restart"), 0, ...updateCommands);
        return all;
    }

    function opened() {
        updates.reload();
    }

    function row(item): var {
        const action = {
            id: item.id,
            label: item.title,
            exec: item.command,
            destructive: item.destructive
        };
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

    StateFile {
        id: updates
        path: root.updatesPath
        absent: false
        parse: text => JSON.parse(text).pending === true
    }
}

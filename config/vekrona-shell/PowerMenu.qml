import "."

Picker {
    id: root

    ipcTarget: "powermenu"
    namespace: "vekrona-powermenu"
    searchable: false
    rows: 5
    items: [
        {
            label: "Lock",
            glyph: "lock",
            command: ["vekrona-lock"]
        },
        {
            label: "Suspend",
            glyph: "bedtime",
            command: ["systemctl", "suspend"]
        },
        {
            label: "Log out",
            glyph: "logout",
            command: ["swaymsg", "exit"]
        },
        {
            label: "Restart",
            glyph: "restart_alt",
            command: ["systemctl", "reboot"]
        },
        {
            label: "Shut down",
            glyph: "power_settings_new",
            command: ["systemctl", "poweroff"]
        }
    ]
    onChosen: item => Exec.detached(item.command)
}

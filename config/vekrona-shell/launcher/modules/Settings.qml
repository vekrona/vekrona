import QtQuick
import ".."
import "../.." as Shell
import "../../Vekrona"

// Theme, night light, caffeine, Wi-Fi, Bluetooth and its pairing, the VPN, audio output, the coding agent, keybindings and updates.
LauncherModule {
    id: root

    // The state the shell cannot read live: set by refresh() from the status commands.
    property bool nightOn: false
    // The Wi-Fi network a connect was started on, until it connects or fails.
    property var attempt: null
    // Whether this opening of the launcher asked for the VPN list (see loadVpnListOnce).
    property bool vpnListLoaded: false

    readonly property var audioView: ({
            title: "Audio output",
            viewId: "audio"
        })
    readonly property var bluetoothView: ({
            title: "Pair a Bluetooth device",
            viewId: "bluetooth"
        })
    readonly property var keyboardView: ({
            title: "Keyboard layouts",
            viewId: "keyboard"
        })
    readonly property var wifiView: ({
            title: "Wi-Fi networks",
            viewId: "wifi"
        })
    readonly property var agentView: ({
            title: "Agent tool",
            viewId: "agent"
        })
    readonly property var vpnView: ({
            title: "VPN",
            viewId: "vpn"
        })
    // Every subview by its viewId, for the host's `launcher settings <viewId>` IPC.
    readonly property var views: ({
            audio: audioView,
            bluetooth: bluetoothView,
            keyboard: keyboardView,
            wifi: wifiView,
            agent: agentView,
            vpn: vpnView
        })
    readonly property var settingRows: buildRows()
    // What the Wi-Fi, Bluetooth, audio, keyboard and VPN views show, to tell the host to re-query only when it changes.
    readonly property string subviewState: JSON.stringify([Shell.Wireless.wifiNetworks.map(network => [network.name, network.connected, network.known]), Shell.Wireless.scanning, Shell.Wireless.unpairedDevices.map(device => [device.address, device.name, device.pairing]), Shell.Audio.sinks.map(sink => sink.name), Shell.Audio.sink?.name ?? "", Shell.Keyboard?.layouts.map(layout => [layout.id, layout.name]) ?? [], Shell.Keyboard?.activeIndex ?? -1, Shell.VpnState.mullvadLoggedIn, Shell.VpnState.catalog, Shell.VpnState.listFailure])

    function setting(key: string, heading: string, icon: string, fields: var): var {
        return Object.assign({
            id: "settings:" + key,
            title: heading,
            glyph: icon,
            kind: "Setting"
        }, fields);
    }

    function buildRows(): var {
        const theme = VekronaTheme.mode === "light" ? "dark" : "light";
        const wifi = Shell.Wireless.wifiEnabled;
        const bluetooth = Shell.Wireless.bluetoothEnabled;
        const muted = Shell.Audio.muted;
        const rows = [
            setting("theme", "Switch to " + theme, theme + "_mode", {
                subtitle: "Now " + VekronaTheme.mode,
                keywords: ["theme", "dark", "light", "mode", "appearance", "colors"],
                aliases: ["theme"],
                actions: [
                    {
                        id: "switch",
                        label: "Switch to " + theme,
                        exec: ["vekrona-theme", theme]
                    }
                ]
            }),
            setting("night", nightOn ? "Turn night light off" : "Turn night light on", "nightlight", {
                subtitle: nightOn ? "Now on" : "Now off",
                keywords: ["night", "night light", "warm", "blue light", "eyes", "redshift"],
                aliases: ["night"],
                actions: [
                    {
                        id: "toggle",
                        label: nightOn ? "Turn off" : "Turn on",
                        exec: ["vekrona-night", "toggle"]
                    }
                ]
            })
        ];
        for (const step of Shell.Caffeine.presets) {
            rows.push(setting("caffeine:" + step, "Keep awake for " + step, "local_cafe", {
                keywords: ["caffeine", "coffee", "awake", "sleep", "suspend", "inhibit"],
                aliases: ["caffeine", "coffee"],
                checked: Shell.Caffeine.kind === "for" && Shell.Caffeine.preset === step,
                actions: [
                    {
                        id: "start",
                        label: "Keep awake for " + step,
                        run: () => root.startCaffeine(["for", step])
                    }
                ]
            }));
        }
        rows.push(setting("caffeine:off", "Stop keeping awake", "local_cafe", {
            keywords: ["caffeine", "coffee", "awake", "sleep", "suspend", "inhibit", "off"],
            aliases: ["caffeine", "coffee"],
            actions: [
                {
                    id: "stop",
                    label: "Stop keeping awake",
                    run: () => root.stopCaffeine()
                }
            ]
        }));
        rows.push(setting("wifi", wifi ? "Turn Wi-Fi off" : "Turn Wi-Fi on", wifi ? "wifi" : "wifi_off", {
            subtitle: wifi ? "Now on" : "Now off",
            keywords: ["wifi", "wi-fi", "wireless", "network", "internet", "airplane"],
            aliases: ["wifi"],
            actions: [
                {
                    id: "toggle",
                    label: wifi ? "Turn off" : "Turn on",
                    run: () => root.switchWifi()
                }
            ]
        }));
        rows.push(setting("wifi-networks", "Wi-Fi networks", "wifi", {
            subtitle: Shell.Wireless.connectedWifi ? "Connected to " + Shell.Wireless.connectedWifi.name : "Not connected",
            keywords: ["wifi", "wi-fi", "wireless", "network", "networks", "connect", "ssid", "internet"],
            actions: [
                {
                    id: "open",
                    label: "Show networks",
                    push: root.wifiView
                }
            ]
        }));
        if (Shell.Wireless.adapter) {
            rows.push(setting("bluetooth", bluetooth ? "Turn Bluetooth off" : "Turn Bluetooth on", bluetooth ? "bluetooth" : "bluetooth_disabled", {
                subtitle: Shell.Wireless.bluetoothBlocked ? "Blocked by rfkill" : bluetooth ? "Now on" : "Now off",
                keywords: ["bluetooth", "bt", "wireless", "headphones", "pair", "rfkill"],
                aliases: ["bt", "bluetooth"],
                actions: [
                    {
                        id: "toggle",
                        label: bluetooth ? "Turn off" : "Turn on",
                        run: () => root.switchBluetooth()
                    }
                ]
            }));
            if (bluetooth) {
                rows.push(setting("bluetooth-pair", "Pair a Bluetooth device", "bluetooth_searching", {
                    subtitle: Shell.Wireless.scanning ? "Searching for devices" : "Put the device in pairing mode first",
                    keywords: ["bluetooth", "bt", "pair", "scan", "headphones", "controller", "mouse", "keyboard", "new"],
                    aliases: ["pair"],
                    actions: [
                        {
                            id: "scan",
                            label: "Scan for devices",
                            run: () => root.scanBluetooth()
                        }
                    ]
                }));
            }
        }
        rows.push(setting("vpn", "VPN", "vpn_lock", {
            keywords: ["vpn", "wireguard", "mullvad", "proton", "tunnel", "kill switch", "privacy", "connect"],
            aliases: ["vpn"],
            actions: [
                {
                    id: "open",
                    label: "Choose connection",
                    push: root.vpnView
                }
            ]
        }));
        rows.push(setting("audio-output", "Audio output", "speaker", {
            subtitle: Shell.Audio.sink ? Shell.Audio.sink.description : "No output",
            keywords: ["audio", "sound", "output", "speakers", "headphones", "sink", "volume"],
            aliases: ["audio", "sound", "output"],
            actions: [
                {
                    id: "open",
                    label: "Choose output",
                    push: root.audioView
                }
            ]
        }));
        const keyboardLayoutNames = (Shell.Keyboard?.layouts ?? []).map(layout => layout.name);
        rows.push(setting("keyboard-layouts", "Keyboard layouts", "keyboard", {
            subtitle: keyboardLayoutNames.length > 0 ? keyboardLayoutNames.join(", ") : "No layouts",
            keywords: ["keyboard", "layout", "language", "input", "xkb", "ukrainian", "switch"],
            aliases: ["keyboard", "layout"],
            actions: [
                {
                    id: "change",
                    label: "Change layouts",
                    push: root.keyboardView
                }
            ]
        }));
        rows.push(setting("mute", muted ? "Unmute" : "Mute", muted ? "volume_up" : "volume_off", {
            subtitle: muted ? "Sound is off" : "Sound is on",
            keywords: ["audio", "sound", "volume", "mute", "silence", "speakers"],
            aliases: ["mute", "volume"],
            actions: [
                {
                    id: "toggle",
                    label: muted ? "Unmute" : "Mute",
                    run: () => Shell.Audio.toggleMute()
                }
            ]
        }));
        rows.push(setting("agent", "Agent tool", "smart_toy", {
            keywords: ["agent", "coding", "ai", "claude", "codex", "tool", "default"],
            aliases: ["agent"],
            actions: [
                {
                    id: "open",
                    label: "Choose tool",
                    push: root.agentView
                }
            ]
        }));
        rows.push(setting("keybindings", "Keybindings", "keyboard", {
            keywords: ["keys", "keybindings", "shortcuts", "hotkeys", "bindings", "help"],
            aliases: ["keys"],
            actions: [
                {
                    id: "show",
                    label: "Show keybindings",
                    exec: ["vekrona-keybindings", "menu"]
                }
            ]
        }));
        rows.push(setting("update", "Update system", "system_update", {
            keywords: ["update", "upgrade", "dnf", "flatpak", "packages"],
            aliases: ["update", "upgrade"],
            actions: [
                {
                    id: "run",
                    label: "Update in a terminal",
                    exec: Shell.Exec.inTerminal(["bash", "-c", 'vekrona-update now; status=$?; read -rp "vekrona-update exited with $status. Press Enter to close. "; exit "$status"'])
                }
            ]
        }));
        return rows;
    }

    function wifiRows(): var {
        return Shell.Wireless.wifiNetworks.map(network => ({
                    id: "settings:wifi:" + network.name,
                    title: network.name,
                    subtitle: network.connected ? "Connected" : network.known ? "Saved" : Shell.Wireless.needsPassword(network) ? "Needs a password" : "",
                    glyph: Shell.Wireless.wifiGlyph(network.signalStrength),
                    kind: "Wi-Fi network",
                    keywords: ["wifi", "network"],
                    checked: network.connected,
                    actions: [
                        {
                            id: "connect",
                            label: network.connected ? "Disconnect" : "Connect",
                            run: () => root.chooseNetwork(network)
                        }
                    ]
                }));
    }

    // The scan control, then the devices found that are not paired yet.
    function bluetoothRows(): var {
        const scanning = Shell.Wireless.scanning;
        const rows = [
            {
                id: "settings:bluetooth:scan",
                title: scanning ? "Searching for devices" : "Not searching",
                subtitle: "Put the device in pairing mode",
                glyph: "bluetooth_searching",
                kind: "Bluetooth",
                actions: [
                    {
                        id: "scan",
                        label: scanning ? "Stop scanning" : "Scan again",
                        run: () => {
                            Shell.Wireless.setScanning(!scanning);
                            return false;
                        }
                    }
                ]
            }
        ];
        for (const device of Shell.Wireless.unpairedDevices) {
            rows.push({
                id: "settings:bluetooth:" + device.address,
                title: device.name,
                subtitle: device.pairing ? "Pairing" : "",
                glyph: device.pairing ? "sync" : "bluetooth",
                kind: "Bluetooth device",
                keywords: ["bluetooth", "pair"],
                actions: [
                    {
                        id: "pair",
                        label: "Pair",
                        run: () => root.pairBluetooth(device)
                    }
                ]
            });
        }
        return rows;
    }

    function audioRows(): var {
        return Shell.Audio.sinks.map(sink => ({
                    id: "settings:sink:" + sink.name,
                    title: sink.description || sink.name,
                    glyph: "speaker",
                    kind: "Audio output",
                    keywords: ["audio", "sound", "output"],
                    checked: sink === Shell.Audio.sink,
                    actions: [
                        {
                            id: "select",
                            label: "Use as output",
                            run: () => Shell.Audio.selectSink(sink)
                        }
                    ]
                }));
    }

    function keyboardRows(): var {
        const layouts = Shell.Keyboard?.layouts ?? [];
        const activeIndex = Shell.Keyboard?.activeIndex ?? -1;
        const currentNames = layouts.map(layout => layout.name).join(", ");
        const commandIds = layouts.map(layout => layout.id).join(",");
        const rows = [
            {
                id: "settings:keyboard:info",
                title: "Layouts come from your system keymap. Now: " + (currentNames || "none"),
                glyph: "info",
                kind: "Keyboard info"
            },
            {
                id: "settings:keyboard:command",
                title: "To add or remove a layout, run: sudo localectl set-x11-keymap " + (commandIds || "us"),
                glyph: "terminal",
                kind: "Keyboard command",
                actions: [
                    {
                        id: "copy",
                        label: "Copy command",
                        copy: "sudo localectl set-x11-keymap " + (commandIds || "us")
                    }
                ]
            },
            {
                id: "settings:keyboard:signout",
                title: "Then sign out and sign back in.",
                glyph: "logout",
                kind: "Keyboard signout"
            },
            {
                id: "settings:keyboard:keybind",
                title: "Next layout: Hyper+Space",
                glyph: "keyboard",
                kind: "Keyboard keybind"
            }
        ];
        return rows;
    }

    // The connections of `vekrona-vpn list`, flat: a Mullvad country is one row (none while Mullvad is logged out, as the bar's
    // popout shows its login field instead), any other vendor's configuration is one, and the first row turns the VPN off. The
    // bar's popout walks the same tree level by level.
    function vpnRows(): var {
        if (Shell.VpnState.listFailure !== "")
            return [errorRow("list the VPN connections", Shell.VpnState.listFailure)];
        const rows = [
            {
                id: "settings:vpn:off",
                title: "Turn the VPN off",
                glyph: "vpn_key_off",
                kind: "VPN",
                keywords: ["vpn", "off", "disconnect", "kill switch"],
                actions: [
                    {
                        id: "off",
                        label: "Turn off",
                        run: () => root.vpnCommand(["off"], "Turning the VPN off", "The VPN is off")
                    }
                ]
            }
        ];
        for (const vendor of Shell.VpnState.catalog) {
            if (Shell.VpnState.needsLogin(vendor.id))
                continue;
            for (const country of vendor.countries) {
                for (const choice of Shell.VpnState.connectChoices(vendor, country)) {
                    rows.push({
                        id: "settings:vpn:" + vendor.id + ":" + choice.key,
                        title: choice.name,
                        subtitle: choice.context,
                        glyph: "vpn_lock",
                        kind: "VPN connection",
                        keywords: ["vpn", vendor.label, country.name, country.code],
                        actions: [
                            {
                                id: "connect",
                                label: "Connect",
                                run: () => root.vpnClosingCommand(choice.args)
                            }
                        ]
                    });
                }
            }
        }
        return rows;
    }

    // Asks for the list once per opening of the launcher, when the VPN view is first wanted: the list can cost a request to Mullvad,
    // which opening the launcher for anything else must not make (the view is asked again at every key press).
    function loadVpnListOnce(): void {
        if (vpnListLoaded)
            return;
        vpnListLoaded = true;
        Shell.VpnState.loadList();
    }

    // Runs a vekrona-vpn command and toasts how it ended. Returns false: the launcher stays open to show that.
    function vpnCommand(args: list<string>, progress: string, done: string): bool {
        launcher.toast(progress);
        Shell.VpnState.command(args, stdout => launcher.toast(done), reason => launcher.toast(reason));
        return false;
    }

    // Runs a vekrona-vpn command that may prompt the keyring (a connect): the launcher closes first, so that the prompt gets the
    // keyboard, and a failure is a notification, as the bar's popout reports it. Returns true: the launcher closes.
    function vpnClosingCommand(args: list<string>): bool {
        Shell.VpnState.command(args, stdout => {}, reason => Shell.Exec.check(["notify-send", "-a", "vekrona", "VPN", reason]));
        return true;
    }

    // vekrona-agent list prints "<tool>  installed|not installed  default|-" per tool.
    function agentRows(output: string): var {
        const rows = [];
        for (const line of output.split("\n").map(l => l.trim()).filter(l => l !== "")) {
            const match = /^(\S+)\s+(installed|not installed)\s+(default|-)$/.exec(line);
            if (!match) {
                console.error("Settings: cannot read this line of `vekrona-agent list`: " + line);
                launcher.toast("Cannot read the agent tool list");
                continue;
            }
            if (match[2] !== "installed")
                continue;
            rows.push({
                id: "settings:agent:" + match[1],
                title: match[1],
                glyph: "smart_toy",
                kind: "Agent tool",
                checked: match[3] === "default",
                actions: [
                    {
                        id: "set",
                        label: "Use as the default agent",
                        exec: ["vekrona-agent", "set", match[1]]
                    }
                ]
            });
        }
        return rows;
    }

    function loadAgents(reqId: int): void {
        const argv = ["vekrona-agent", "list"];
        answerFrom(reqId, argv, (code, stdout, stderr) => code !== 0 ? [errorRow("list the agent tools", Shell.Exec.failure(argv, code, stderr))] : agentRows(stdout));
    }

    // Toasts why a toggle was refused and returns false then, so the launcher stays open to show it.
    function report(refusal: string): bool {
        if (refusal === "")
            return true;
        launcher.toast(refusal);
        return false;
    }

    function switchWifi(): bool {
        return report(Shell.Wireless.toggleWifi());
    }

    // Returns false while rfkill is being lifted, so the launcher stays open to show how that ended.
    function switchBluetooth(): bool {
        const unblocking = Shell.Wireless.bluetoothBlocked;
        Shell.Wireless.toggleBluetooth(reason => launcher.toast(reason));
        return !unblocking;
    }

    function scanBluetooth(): bool {
        Shell.Wireless.setScanning(true);
        launcher.pushView(moduleId, bluetoothView);
        return false;
    }

    // Returns false: the launcher stays open to show how the pairing ended.
    function pairBluetooth(device): bool {
        launcher.toast("Pairing with " + device.name);
        Shell.Wireless.pairDevice(device, reason => launcher.toast(reason));
        return false;
    }

    // Returns false while a connect is under way, so the launcher stays open to show how it ended.
    function chooseNetwork(network): bool {
        if (Shell.Wireless.needsPassword(network)) {
            launcher.toast(network.name + " needs a password: join it once from the bar's network menu");
            return false;
        }
        const connecting = !network.connected;
        attempt = connecting ? network : null;
        Shell.Wireless.toggleConnection(network);
        if (connecting)
            launcher.toast("Connecting to " + network.name);
        return !connecting;
    }

    // Reads whether night light is on. A failure is logged, which records it, and leaves the state as it was.
    function refresh(): void {
        Shell.Exec.runChecked(["systemctl", "--user", "show", "vekrona-night.service", "--property=ActiveState", "--value"], output => {
            nightOn = output.trim() === "active";
        });
    }

    // Starts or ends a keep-awake session, and toasts why the command refused (like a time span it cannot read).
    function startCaffeine(args: list<string>): void {
        Shell.Caffeine.start(args, reason => launcher.toast(reason));
    }

    function stopCaffeine(): void {
        Shell.Caffeine.stop(reason => launcher.toast(reason));
    }

    function opened(): void {
        refresh();
        vpnListLoaded = false;
    }

    function closed(): void {
        Shell.Wireless.setScanning(false);
    }

    function query(text, reqId) {
        return settingRows;
    }

    function view(viewId, text, reqId) {
        switch (viewId) {
        case "wifi":
            return wifiRows();
        case "bluetooth":
            return bluetoothRows();
        case "audio":
            return audioRows();
        case "keyboard":
            return keyboardRows();
        case "agent":
            loadAgents(reqId);
            return null;
        case "vpn":
            loadVpnListOnce();
            return vpnRows();
        }
        console.error("Settings: unknown view " + viewId);
        return [];
    }

    moduleId: "settings"
    title: "Settings"
    glyph: "settings"
    slash: "settings"
    weight: 0.9
    onSettingRowsChanged: changed()
    onSubviewStateChanged: changed()

    Connections {
        target: root.attempt
        ignoreUnknownSignals: true

        function onConnectedChanged(): void {
            if (!root.attempt.connected)
                return;
            root.launcher.toast("Connected to " + root.attempt.name);
            root.attempt = null;
        }

        function onConnectionFailed(reason): void {
            root.launcher.toast(Shell.Wireless.failureText(root.attempt, reason));
            root.attempt = null;
        }
    }
}

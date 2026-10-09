import QtQuick
import ".."
import "../.." as Shell
import "../../Vekrona"

// Theme, night light, caffeine, Wi-Fi, Bluetooth, audio output, the coding agent, keybindings and updates.
LauncherModule {
    id: root

    // The state the shell cannot read live: set by refresh() from the status commands.
    property bool nightOn: false
    // The duration caffeine was started for ("30m", "1h", "2h"), "" when it is off.
    property string caffeine: ""
    // The Wi-Fi network a connect was started on, until it connects or fails.
    property var attempt: null

    readonly property var caffeineSteps: [
        {
            value: "30m",
            label: "30 minutes"
        },
        {
            value: "1h",
            label: "1 hour"
        },
        {
            value: "2h",
            label: "2 hours"
        }
    ]
    readonly property var audioView: ({
            title: "Audio output",
            viewId: "audio"
        })
    readonly property var settingRows: buildRows()
    // What the Wi-Fi and audio views show, to tell the host to re-query only when it changes.
    readonly property string subviewState: JSON.stringify([Shell.Wireless.wifiNetworks.map(network => [network.name, network.connected, network.known]), Shell.Audio.sinks.map(sink => sink.name), Shell.Audio.sink?.name ?? ""])

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
        for (const step of caffeineSteps) {
            rows.push(setting("caffeine:" + step.value, "Keep awake for " + step.label, "coffee", {
                keywords: ["caffeine", "coffee", "awake", "sleep", "suspend", "inhibit"],
                aliases: ["caffeine", "coffee"],
                checked: caffeine === step.value,
                actions: [
                    {
                        id: "start",
                        label: "Keep awake for " + step.label,
                        exec: ["vekrona-caffeine", step.value]
                    }
                ]
            }));
        }
        rows.push(setting("caffeine:off", "Stop keeping awake", "coffee", {
            keywords: ["caffeine", "coffee", "awake", "sleep", "suspend", "inhibit", "off"],
            aliases: ["caffeine", "coffee"],
            actions: [
                {
                    id: "stop",
                    label: "Stop keeping awake",
                    exec: ["vekrona-caffeine", "off"]
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
                    push: {
                        title: "Wi-Fi networks",
                        viewId: "wifi"
                    }
                }
            ]
        }));
        if (Shell.Wireless.adapter) {
            rows.push(setting("bluetooth", bluetooth ? "Turn Bluetooth off" : "Turn Bluetooth on", bluetooth ? "bluetooth" : "bluetooth_disabled", {
                subtitle: bluetooth ? "Now on" : "Now off",
                keywords: ["bluetooth", "bt", "wireless", "headphones", "pair"],
                aliases: ["bt", "bluetooth"],
                actions: [
                    {
                        id: "toggle",
                        label: bluetooth ? "Turn off" : "Turn on",
                        run: () => root.switchBluetooth()
                    }
                ]
            }));
        }
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
                    push: {
                        title: "Agent tool",
                        viewId: "agent"
                    }
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
                    exec: ["vekrona-keybindings"]
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
                    exec: Shell.Exec.inTerminal(["bash", "-c", 'vekrona-update; status=$?; read -rp "vekrona-update exited with $status. Press Enter to close. "; exit "$status"'])
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

    function switchBluetooth(): bool {
        return report(Shell.Wireless.toggleBluetooth());
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

    function parseCaffeine(output: string): string {
        const status = output.trim();
        if (status === "caffeine: off")
            return "";
        const match = /^caffeine: on \(caffeine (30m|1h|2h)\)$/.exec(status);
        if (!match) {
            console.error("Settings: cannot read the output of `vekrona-caffeine status`: " + status);
            return "";
        }
        return match[1];
    }

    // Runs a status command and applies its output. A failure is logged and leaves the state as it was.
    function readStatus(argv: list<string>, apply): void {
        Shell.Exec.run(argv, (code, stdout, stderr) => {
            if (code !== 0)
                Shell.Exec.failure(argv, code, stderr);
            else
                apply(stdout);
        });
    }

    function refresh(): void {
        readStatus(["systemctl", "--user", "show", "vekrona-night.service", "--property=ActiveState", "--value"], output => {
            nightOn = output.trim() === "active";
        });
        readStatus(["vekrona-caffeine", "status"], output => {
            caffeine = parseCaffeine(output);
        });
    }

    // Runs a status-changing command in a transient unit like Exec.detached, waits for it, then reads the state again.
    function runAndRefresh(argv: list<string>): void {
        Shell.Exec.run(Shell.Exec.unit(argv, true), (code, stdout, stderr) => {
            if (code !== 0)
                launcher.toast("Couldn’t run " + argv[0] + ": " + Shell.Exec.failure(argv, code, stderr));
            root.refresh();
        });
    }

    function opened(): void {
        refresh();
    }

    function query(text, reqId) {
        return settingRows;
    }

    function view(viewId, text, reqId) {
        switch (viewId) {
        case "wifi":
            return wifiRows();
        case "audio":
            return audioRows();
        case "agent":
            loadAgents(reqId);
            return null;
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

    // A square 32 px button with its glyph and a short label below; the selected fill marks it on.
    component Toggle: Item {
        id: toggle

        required property string glyph
        required property string label
        property bool active: false
        property bool checkable: true
        property bool focused: false

        signal activated

        implicitWidth: Math.max(VekronaTheme.sizeTarget, caption.implicitWidth)
        implicitHeight: VekronaTheme.sizeTarget + VekronaTheme.space1 + caption.implicitHeight

        Accessible.role: Accessible.Button
        Accessible.name: label
        Accessible.checkable: checkable
        Accessible.checked: active

        Rectangle {
            id: square

            anchors.horizontalCenter: parent.horizontalCenter
            width: VekronaTheme.sizeTarget
            height: VekronaTheme.sizeTarget
            color: mouse.pressed ? VekronaTheme.c.surface3 : mouse.containsMouse ? VekronaTheme.c.surface2 : "transparent"
            border.width: VekronaTheme.borderControl
            border.color: VekronaTheme.c.line

            Selection {
                shown: toggle.active
            }

            Pictogram {
                anchors.centerIn: parent
                name: toggle.glyph
                filled: toggle.active
            }

            FocusRing {
                shown: toggle.focused
            }
        }

        Label {
            id: caption

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: square.bottom
            anchors.topMargin: VekronaTheme.space1
            style: VekronaTheme.type.caption
            text: toggle.label
        }

        MouseArea {
            id: mouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: toggle.activated()
        }
    }

    widget: Component {
        FocusScope {
            id: strip

            property var launcher: root.launcher
            property var module: root
            readonly property var toggles: [theme, night, caffeineToggle, wifi, bluetooth, audio]
            property Item current: theme

            function step(delta: int): void {
                const shown = toggles.filter(toggle => toggle.visible);
                const index = shown.indexOf(current);
                current = shown[Math.max(0, Math.min(shown.length - 1, index < 0 ? 0 : index + delta))];
            }

            implicitWidth: row.implicitWidth
            implicitHeight: row.implicitHeight
            Keys.onLeftPressed: step(-1)
            Keys.onRightPressed: step(1)
            Keys.onReturnPressed: current.activated()
            Keys.onEnterPressed: current.activated()
            Keys.onSpacePressed: current.activated()

            Row {
                id: row

                spacing: VekronaTheme.space2

                Toggle {
                    id: theme

                    glyph: VekronaTheme.mode === "light" ? "light_mode" : "dark_mode"
                    label: "Theme"
                    active: VekronaTheme.mode !== "light"
                    focused: strip.activeFocus && strip.current === theme
                    onActivated: Shell.Exec.detached(["vekrona-theme", VekronaTheme.mode === "light" ? "dark" : "light"])
                }

                Toggle {
                    id: night

                    glyph: "nightlight"
                    label: "Night"
                    active: root.nightOn
                    focused: strip.activeFocus && strip.current === night
                    onActivated: root.runAndRefresh(["vekrona-night", "toggle"])
                }

                Toggle {
                    id: caffeineToggle

                    glyph: "coffee"
                    label: "Caffeine"
                    active: root.caffeine !== ""
                    focused: strip.activeFocus && strip.current === caffeineToggle
                    onActivated: root.runAndRefresh(["vekrona-caffeine", root.caffeine === "" ? "1h" : "off"])
                }

                Toggle {
                    id: wifi

                    glyph: Shell.Wireless.wifiEnabled ? "wifi" : "wifi_off"
                    label: "Wi-Fi"
                    active: Shell.Wireless.wifiEnabled
                    focused: strip.activeFocus && strip.current === wifi
                    onActivated: root.switchWifi()
                }

                Toggle {
                    id: bluetooth

                    visible: Shell.Wireless.adapter !== null
                    glyph: Shell.Wireless.bluetoothEnabled ? "bluetooth" : "bluetooth_disabled"
                    label: "Bluetooth"
                    active: Shell.Wireless.bluetoothEnabled
                    focused: strip.activeFocus && strip.current === bluetooth
                    onActivated: root.switchBluetooth()
                }

                Toggle {
                    id: audio

                    glyph: Shell.Audio.glyph
                    label: "Audio"
                    checkable: false
                    focused: strip.activeFocus && strip.current === audio
                    onActivated: strip.launcher.pushView(root.moduleId, root.audioView)
                }
            }
        }
    }
}

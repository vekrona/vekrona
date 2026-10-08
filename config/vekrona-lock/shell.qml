// Lock screen, started by bin/vekrona-lock as a transient user unit: the
// process lives for exactly one lock. It locks on start and quits after unlock.
//
// Three PAM stacks run side by side and any success unlocks:
//   password     always; the typed text answers its prompt
//   security key while udev reports a FIDO device (fido-keys.sh)
//   fingerprint  when fprintd-list shows enrolled fingers
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string passwordPrompt: "Password"
    // The design system fixes the focus ring offset (token "focus") at 2px; it has no size token of its own.
    readonly property real focusOffset: 2

    // ---- Theme: tokens.json, the Vekrona Design System (config/tokens.json, linked next to this file).
    // A lock screen must always render, so anything unreadable or missing falls back to fallback().
    property var tokens: null
    // dark unless the desktop asks for light; read once at lock start.
    property string mode: "dark"

    function fallback(kind, name) {
        switch (kind) {
        case "color":
            return name === "bg" ? "black" : "white";
        case "px":
            return 16;
        default:
            return {
                family: "sans-serif",
                size: 16,
                weight: 400,
                lineHeight: 24,
                letterSpacing: 0
            };
        }
    }

    // The value of the named token in the first of the groups that has it.
    function findToken(groups, name) {
        for (const group of groups) {
            const found = tokens[group].tokens.find(t => t.name === name);
            if (found)
                return found.value;
        }
        throw new Error("no token " + name);
    }

    // Runs read() against the loaded tokens; tokens is null until tokens.json is loaded.
    function lookup(kind, name, read) {
        if (tokens === null)
            return fallback(kind, name);
        try {
            return read();
        } catch (e) {
            console.error("vekrona-lock: token", name, "unusable:", e);
            return fallback(kind, name);
        }
    }

    function token(name) {
        return lookup("color", name, () => findToken(["color"], name)[mode]);
    }

    function size(name) {
        return lookup("px", name, () => parseFloat(findToken(["size", "border", "spacing"], name)));
    }

    function typeStyle(name) {
        return lookup("type", name, () => {
            for (const group of tokens.type.groups) {
                const style = group.styles.find(s => s.name === name);
                if (!style)
                    continue;
                const family = tokens.type.families[group.family].split(",")[0].trim().replace(/^["']|["']$/g, "");
                const fontSize = parseFloat(style.fontSize);
                return {
                    family: family,
                    size: fontSize,
                    weight: style.fontWeight,
                    lineHeight: parseFloat(style.lineHeight),
                    letterSpacing: style.letterSpacing ? parseFloat(style.letterSpacing) * fontSize : 0
                };
            }
            throw new Error("no type style " + name);
        });
    }

    function typeFont(name) {
        const style = typeStyle(name);
        return Qt.font({
            family: style.family,
            pixelSize: style.size,
            weight: style.weight,
            letterSpacing: style.letterSpacing
        });
    }

    FileView {
        path: Quickshell.shellPath("tokens.json")
        blockLoading: true
        onLoaded: {
            try {
                root.tokens = JSON.parse(text());
            } catch (e) {
                console.error("vekrona-lock: tokens.json is not valid JSON:", e);
            }
        }
        onLoadFailed: error => console.error("vekrona-lock: cannot read tokens.json:", error)
    }

    Process {
        running: true
        command: ["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"]
        stdout: StdioCollector {
            id: colorScheme
        }
        onExited: exitCode => {
            if (exitCode !== 0)
                console.error("vekrona-lock: gsettings exited with", exitCode, "; using the dark tokens");
            else if (colorScheme.text.includes("prefer-light"))
                root.mode = "light";
        }
    }

    // ---- Unlock sequence: loginctl unlock-session, LockedHint=false, unlock, quit.
    property bool unlocking: false

    component LogindStep: Process {
        signal finished

        onExited: exitCode => {
            if (exitCode !== 0)
                console.error("vekrona-lock:", command.join(" "), "exited with", exitCode);
            finished();
        }
    }

    LogindStep {
        id: setHint
        command: ["busctl", "call", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session", "SetLockedHint", "b", "true"]
    }

    LogindStep {
        id: unlockSession
        command: ["loginctl", "unlock-session"]
        onFinished: clearHint.running = true
    }

    LogindStep {
        id: clearHint
        command: ["busctl", "call", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session", "SetLockedHint", "b", "false"]
        onFinished: {
            lock.locked = false;
            Qt.quit();
        }
    }

    function unlock() {
        if (unlocking)
            return;
        unlocking = true;
        password.abort();
        u2f.abort();
        fprint.abort();
        unlockSession.running = true;
    }

    // ---- Status line. A PAM error wins over the hint of what to do.
    property string failure: ""
    property bool keyWatcherFailed: false
    // The key is plugged in but every attempt failed before the touch cue: give up until it is replugged.
    readonly property bool keyGaveUp: keyCount > 0 && !u2f.active && u2f.quickFailures >= maxQuickFailures
    readonly property bool statusIsError: failure !== "" || keyWatcherFailed || keyGaveUp
    readonly property string status: {
        if (failure !== "")
            return failure;
        if (keyWatcherFailed)
            return "Security key unavailable";
        if (keyGaveUp)
            return "Security key not responding; replug it";
        if (u2f.active)
            return "Touch your security key";
        if (fprint.active)
            return "Touch the fingerprint reader";
        return "";
    }

    // ---- Password
    // The typed text waits here until PAM asks for it.
    property string submitted: ""

    function submit(text) {
        failure = "";
        if (text === "")
            return;
        submitted = text;
        if (password.active)
            password.abort();
        password.start();
    }

    PamContext {
        id: password
        configDirectory: "/etc/pam.d"
        config: "vekrona-lock-password"

        onResponseRequiredChanged: {
            if (responseRequired && root.submitted !== "") {
                respond(root.submitted);
                root.submitted = "";
            }
        }
        onCompleted: result => {
            if (result === PamResult.Success)
                root.unlock();
            else if (!root.unlocking)
                root.failure = messageIsError && message !== "" ? message : "Authentication failed";
        }
    }

    // ---- Security key
    property int keyCount: 0
    // Bumped by every plug or unplug, so an attempt that outlived a key change retries.
    property int keyEvents: 0
    readonly property int maxQuickFailures: 30

    function syncKey() {
        if (keyCount > 0 && !unlocking && !u2f.active) {
            u2f.touched = false;
            u2f.startedAt = keyEvents;
            u2f.start();
        } else if (keyCount === 0 && u2f.active) {
            u2f.abort();
        }
    }

    onKeyCountChanged: {
        keyEvents++;
        u2f.quickFailures = 0;
        syncKey();
    }

    PamContext {
        id: u2f
        configDirectory: "/etc/pam.d"
        config: "vekrona-lock-u2f"

        property bool touched: false
        property int startedAt: 0
        // Attempts that failed before the touch cue was shown, since the key last changed.
        property int quickFailures: 0

        onMessageChanged: {
            if (message.toLowerCase().includes("touch"))
                touched = true;
            if (messageIsError)
                root.failure = message;
        }
        onCompleted: result => {
            if (result === PamResult.Success) {
                root.unlock();
                return;
            }
            // Retry at once if the user could have touched (the prompt was shown) or the key
            // changed meanwhile. A failure before the cue with the key still there means pam_u2f
            // found the key not ready (it answers CTAP late after enumeration); try again a few
            // times, spaced, but not forever: a key without a registered credential fails at once too.
            if (touched || startedAt !== root.keyEvents) {
                root.syncKey();
            } else if (root.keyCount > 0 && quickFailures < root.maxQuickFailures) {
                quickFailures++;
                retry.restart();
            } else if (root.keyCount > 0) {
                console.error("vekrona-lock: the security key failed", quickFailures, "times before the touch cue; waiting for a replug:", message);
            }
        }
    }

    Timer {
        id: retry
        interval: 1000
        onTriggered: root.syncKey()
    }

    Process {
        id: keyWatcher
        running: true
        command: [Quickshell.shellPath("fido-keys.sh")]
        stdout: SplitParser {
            onRead: line => {
                const count = parseInt(line);
                if (isNaN(count))
                    console.error("vekrona-lock: fido-keys.sh printed", line);
                else
                    root.keyCount = count;
            }
        }
        onExited: exitCode => {
            if (root.unlocking)
                return;
            console.error("vekrona-lock: fido-keys.sh exited with", exitCode);
            root.keyWatcherFailed = true;
            root.keyCount = 0;
        }
    }

    // ---- Fingerprint
    property bool fprintEnrolled: false

    function hasEnrolledFingers(output) {
        const lower = output.toLowerCase();
        return lower.includes("has fingers enrolled") || lower.split(/\r?\n/).some(l => l.trim().startsWith("finger:"));
    }

    function keyPressed() {
        failure = "";
        if (fprintEnrolled && !unlocking && !fprint.active)
            fprint.start();
    }

    Process {
        running: true
        command: ["fprintd-list", Quickshell.env("USER")]
        stdout: StdioCollector {
            id: fprintList
        }
        onExited: exitCode => {
            if (exitCode !== 0) {
                // No reader is a normal machine, not a failure.
                if (!fprintList.text.includes("No devices available"))
                    console.error("vekrona-lock: fprintd-list exited with", exitCode, fprintList.text.trim(), "; no fingerprint unlock");
                return;
            }
            root.fprintEnrolled = root.hasEnrolledFingers(fprintList.text);
            if (root.fprintEnrolled)
                fprint.start();
        }
    }

    PamContext {
        id: fprint
        configDirectory: "/etc/pam.d"
        config: "vekrona-lock-fprint"

        onCompleted: result => {
            if (result === PamResult.Success)
                root.unlock();
            else if (!root.unlocking)
                root.failure = message !== "" ? message : "Fingerprint not recognized";
        }
    }

    // ---- Screens
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    WlSessionLock {
        id: lock
        locked: true
        onSecureChanged: {
            if (secure)
                setHint.running = true;
        }

        WlSessionLockSurface {
            color: root.token("bg")

            onVisibleChanged: field.forceActiveFocus()

            Column {
                id: content
                anchors.centerIn: parent
                spacing: root.size("space-8")

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatTime(clock.date, "HH:mm")
                    color: root.token("ink")
                    font: root.typeFont("display")
                }

                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: root.size("space-2")

                    Text {
                        text: root.passwordPrompt
                        color: root.token("ink-muted")
                        font: root.typeFont("label")
                    }

                    Rectangle {
                        id: fieldFrame
                        // Twelve touch targets wide; tall enough for one body line plus the control padding.
                        width: 12 * root.size("size-target")
                        height: root.typeStyle("body").lineHeight + 2 * root.size("space-3")
                        color: root.token("surface-2")
                        border.width: root.size("border-control")
                        border.color: root.token("line-strong")

                        TextInput {
                            id: field
                            anchors.fill: parent
                            anchors.margins: root.size("space-3")
                            verticalAlignment: TextInput.AlignVCenter
                            echoMode: TextInput.Password
                            color: root.token("ink")
                            selectionColor: root.token("accent")
                            selectedTextColor: root.token("on-accent")
                            font: root.typeFont("body")
                            focus: true

                            onActiveFocusChanged: {
                                if (!activeFocus)
                                    forceActiveFocus();
                            }
                            Keys.onPressed: root.keyPressed()
                            onAccepted: {
                                root.submit(text);
                                text = "";
                            }
                        }

                        // The highlight: the indicator underline in accent under the focused field.
                        Rectangle {
                            visible: field.activeFocus
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: root.size("border-indicator")
                            color: root.token("accent")
                        }

                        // Focus ring: offset so it lands on the surface, not on the control.
                        Rectangle {
                            visible: field.activeFocus
                            anchors.fill: parent
                            anchors.margins: -(root.focusOffset + root.size("border-focus"))
                            color: "transparent"
                            border.width: root.size("border-focus")
                            border.color: root.token("focus")
                        }
                    }
                }

                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    // Fixed height so the layout does not jump when the line is empty.
                    width: fieldFrame.width
                    height: root.typeStyle("label").lineHeight

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.status
                        color: root.token(root.statusIsError ? "danger-ink" : "ink")
                        font: root.typeFont("label")
                    }
                }
            }
        }
    }
}

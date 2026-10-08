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

    // ---- Theme: ~/.local/state/vekrona/active-theme.json, black/white if unreadable.
    property var theme: ({})

    function themeColor(key, fallback) {
        return theme.dark && theme.dark[key] ? theme.dark[key] : fallback;
    }

    readonly property color background: themeColor("background", "black")
    readonly property color foreground: themeColor("backgroundText", "white")
    readonly property color accent: themeColor("primary", "white")
    readonly property color danger: themeColor("error", "white")
    readonly property color outline: themeColor("outline", "white")

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/vekrona/active-theme.json"
        blockLoading: true
        onLoaded: {
            try {
                root.theme = JSON.parse(text());
            } catch (e) {
                console.error("vekrona-lock: active theme is not valid JSON:", e);
            }
        }
        onLoadFailed: error => console.error("vekrona-lock: cannot read the active theme:", error)
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
    readonly property bool statusIsError: failure !== "" || keyWatcherFailed
    readonly property string status: {
        if (failure !== "")
            return failure;
        if (keyWatcherFailed)
            return "Security key unavailable";
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
        syncKey();
    }

    PamContext {
        id: u2f
        configDirectory: "/etc/pam.d"
        config: "vekrona-lock-u2f"

        property bool touched: false
        property int startedAt: 0

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
            // Retry only if the user could have touched (the prompt was shown) or the
            // key changed meanwhile; otherwise an unplugged key would loop forever.
            if (touched || startedAt !== root.keyEvents)
                root.syncKey();
        }
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
                console.warn("vekrona-lock: fprintd-list exited with", exitCode, "; no fingerprint unlock");
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
            color: root.background

            onVisibleChanged: field.forceActiveFocus()

            Column {
                anchors.centerIn: parent
                spacing: 32

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatTime(clock.date, "HH:mm")
                    color: root.foreground
                    font.family: "Atkinson Hyperlegible Next"
                    font.pixelSize: 144
                }

                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    Text {
                        text: root.passwordPrompt
                        color: root.foreground
                        font.family: "Atkinson Hyperlegible Next"
                        font.pixelSize: 20
                    }

                    Rectangle {
                        width: 420
                        height: 56
                        color: "transparent"
                        border.width: 1
                        border.color: field.activeFocus ? root.accent : root.outline

                        TextInput {
                            id: field
                            anchors.fill: parent
                            anchors.margins: 16
                            verticalAlignment: TextInput.AlignVCenter
                            echoMode: TextInput.Password
                            color: root.foreground
                            selectionColor: root.accent
                            font.family: "Atkinson Hyperlegible Next"
                            font.pixelSize: 24
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

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 2
                            color: root.accent
                        }
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    // Fixed height so the layout does not jump when the line is empty.
                    height: 28
                    text: root.status
                    color: root.statusIsError ? root.danger : root.foreground
                    font.family: "Atkinson Hyperlegible Next"
                    font.pixelSize: 20
                }
            }
        }
    }
}

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
import "Vekrona"

ShellRoot {
    id: root
    // A reload while locked (install or git checkout rewriting these files) tears
    // the session lock down mid-lock: Quickshell aborts and Sway paints red.
    settings.watchFiles: false

    readonly property string passwordPrompt: "Password"
    // The lock is always dark, in both themes (VekronaTheme.dark).
    component Label: Text {
        required property var style

        font.family: VekronaTheme.fontSans
        font.pixelSize: style.size
        font.weight: style.weight
        font.letterSpacing: style.tracking * style.size
    }

    component Glyph: Text {
        required property string name
        required property int px

        text: VekronaTheme.icon(name)
        font.family: VekronaTheme.fontIcon
        font.pixelSize: px
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

    // The icon in front of the status: an error, or the security key waiting for a touch.
    readonly property string statusIcon: statusIsError ? "error" : u2f.active ? "key" : ""

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
            color: VekronaTheme.dark.bg

            onVisibleChanged: field.forceActiveFocus()

            Rectangle {
                anchors.fill: parent
                color: Qt.alpha(VekronaTheme.dark.scrim, VekronaTheme.scrimOpacity)
            }

            Column {
                id: content
                anchors.centerIn: parent
                spacing: VekronaTheme.space8

                Column {
                    anchors.horizontalCenter: parent.horizontalCenter

                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        style: VekronaTheme.type.display
                        text: Qt.formatTime(clock.date, "HH:mm")
                        color: VekronaTheme.dark.ink
                    }

                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        style: VekronaTheme.type.title
                        text: Qt.formatDate(clock.date, "dddd, d MMMM")
                        color: VekronaTheme.dark.ink
                    }
                }

                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: VekronaTheme.space2

                    Label {
                        style: VekronaTheme.type.label
                        text: root.passwordPrompt
                        color: VekronaTheme.dark.inkMuted
                    }

                    Rectangle {
                        id: fieldFrame
                        // Twelve touch targets wide; tall enough for one body line plus the control padding.
                        width: 12 * VekronaTheme.sizeTarget
                        height: VekronaTheme.type.body.line + 2 * VekronaTheme.space3
                        color: VekronaTheme.dark.surface2
                        border.width: VekronaTheme.borderControl
                        border.color: VekronaTheme.dark.lineStrong

                        TextInput {
                            id: field
                            anchors.fill: parent
                            anchors.margins: VekronaTheme.space3
                            verticalAlignment: TextInput.AlignVCenter
                            echoMode: TextInput.Password
                            color: VekronaTheme.dark.ink
                            selectionColor: VekronaTheme.dark.accent
                            selectedTextColor: VekronaTheme.dark.onAccent
                            font.family: VekronaTheme.fontSans
                            font.pixelSize: VekronaTheme.type.body.size
                            font.weight: VekronaTheme.type.body.weight
                            font.letterSpacing: VekronaTheme.type.body.tracking * VekronaTheme.type.body.size
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
                            height: VekronaTheme.borderIndicator
                            color: VekronaTheme.dark.accent
                        }

                        // Focus ring: offset so it lands on the surface, not on the control.
                        Rectangle {
                            visible: field.activeFocus
                            anchors.fill: parent
                            anchors.margins: -(VekronaTheme.focusOffset + VekronaTheme.borderFocus)
                            color: "transparent"
                            border.width: VekronaTheme.borderFocus
                            border.color: VekronaTheme.dark.focus
                        }
                    }
                }

                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    // Fixed height so the layout does not jump when the line is empty.
                    width: fieldFrame.width
                    height: Math.max(VekronaTheme.iconS, VekronaTheme.type.label.line)

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: VekronaTheme.space2

                        Glyph {
                            visible: root.statusIcon !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            name: root.statusIcon
                            px: VekronaTheme.iconS
                            color: root.statusIsError ? VekronaTheme.dark.dangerInk : VekronaTheme.dark.ink
                        }

                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            style: VekronaTheme.type.label
                            text: root.status
                            color: root.statusIsError ? VekronaTheme.dark.dangerInk : VekronaTheme.dark.ink
                        }
                    }
                }
            }
        }
    }
}

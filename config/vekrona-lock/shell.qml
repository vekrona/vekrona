// Lock screen, started by bin/vekrona-lock as vekrona-lock.service (Type=notify):
// the process lives for exactly one lock and says READY once the compositor
// confirmed it. It locks on start and quits after unlock.
//
// Three PAM stacks run side by side and any success unlocks:
//   password     always; the typed text answers its prompt
//   security key while udev reports a FIDO device (fido-keys.sh); it asks for the key's PIN, then a touch
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

    // What the field expects, said above it: the key's PIN while pam_u2f asks for it, a password otherwise.
    readonly property string passwordPrompt: "Enter password"
    readonly property string pinPrompt: "Enter security key PIN"
    readonly property string touchPrompt: "Touch your security key"
    // The lock is always dark, in both themes (VekronaTheme.dark).

    // ---- Unlock sequence: loginctl unlock-session, LockedHint=false, unlock, quit.
    property bool unlocking: false

    component CommandStep: Process {
        signal finished

        onExited: exitCode => {
            if (exitCode !== 0)
                console.error("vekrona-lock:", command.join(" "), "exited with", exitCode);
            finished();
        }
    }

    CommandStep {
        id: notifyReady
        command: ["systemd-notify", "--ready"]
    }

    CommandStep {
        id: setHint
        command: ["busctl", "call", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session", "SetLockedHint", "b", "true"]
    }

    CommandStep {
        id: unlockSession
        command: ["loginctl", "unlock-session"]
        onFinished: clearHint.running = true
    }

    CommandStep {
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
    // The key is plugged in but gave up until it is replugged: every attempt failed before the touch cue,
    // or one hung after it (u2f.stalled).
    readonly property bool keyGaveUp: keyCount > 0 && !u2f.active && (u2f.quickFailures >= maxQuickFailures || u2f.stalled)
    readonly property bool statusIsError: failure !== "" || keyWatcherFailed || keyGaveUp
    readonly property string status: {
        if (failure !== "")
            return failure;
        if (keyWatcherFailed)
            return "Security key unavailable";
        if (keyGaveUp)
            return "Security key not responding; replug it";
        if (u2f.active && u2f.touched)
            return touchPrompt;
        if (fprint.active)
            return "Touch the fingerprint reader";
        return "";
    }

    // The icon in front of the status: an error, or the security key waiting for a touch.
    readonly property string statusIcon: statusIsError ? "error" : u2f.active && u2f.touched ? "key" : ""

    // ---- Password
    // The typed text waits here until PAM asks for it.
    property string submitted: ""

    function submit(text) {
        failure = "";
        if (text === "")
            return;
        if (pinExpected) {
            u2f.respond(text);
            return;
        }
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
    // pam_u2f asks for the PIN through the PAM conversation, and the field answers it, unless a password was chosen with
    // Tab. A PIN is guarded by a few attempts per key, so text only counts as one when it was begun after the prompt was
    // on screen: what was typed earlier was meant as a password (the prompt came while the person typed it) and goes there.
    property bool passwordChosen: false
    property bool textBegunAtPrompt: false
    property string fieldText: ""
    readonly property bool pinExpected: u2f.responseRequired && !passwordChosen && (fieldText === "" || textBegunAtPrompt)

    function fieldEdited(text) {
        if (fieldText === "" && text !== "")
            textBegunAtPrompt = u2f.responseRequired && !passwordChosen;
        fieldText = text;
    }

    // Every screen has its own field (the surface is a delegate), so the fields clear themselves on this signal.
    signal fieldsCleared

    function fieldWasEmptied() {
        fieldText = "";
        textBegunAtPrompt = false;
    }

    function clearField() {
        fieldWasEmptied();
        fieldsCleared();
    }

    // Tab swaps between the PIN and the password while the key asks for its PIN.
    function swapTarget() {
        if (!u2f.responseRequired && !passwordChosen)
            return;
        passwordChosen = !passwordChosen;
        failure = "";
        clearField();
    }

    property int keyCount: 0
    // Bumped by every plug or unplug, so an attempt that outlived a key change retries.
    property int keyEvents: 0
    readonly property int maxQuickFailures: 30
    // pam_u2f ends an untouched attempt after about 29 s by itself.
    readonly property int stallTimeoutMs: 40000

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
        if (keyCount === 0)
            passwordChosen = false;
        keyEvents++;
        u2f.quickFailures = 0;
        u2f.stalled = false;
        syncKey();
    }

    PamContext {
        id: u2f
        configDirectory: "/etc/pam.d"
        config: "vekrona-lock-u2f"

        // A PIN begun for a prompt that went away (the attempt ended) must not wait for the next one.
        onResponseRequiredChanged: {
            if (!responseRequired && root.textBegunAtPrompt)
                root.clearField();
        }

        property bool touched: false
        property int startedAt: 0
        // Attempts that failed before the touch cue was shown, since the key last changed.
        property int quickFailures: 0
        // The attempt hung after its touch cue and was aborted (the key ignores touches until replugged).
        property bool stalled: false

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

    // A wedged key never ends its attempt and ignores the touch, and only a replug helps: abort it and
    // say so instead of retrying, which would wedge again.
    Timer {
        id: stallWatchdog
        interval: root.stallTimeoutMs
        running: u2f.active && u2f.touched
        onTriggered: {
            console.error("vekrona-lock: the security key gave no result", interval / 1000, "s after the touch cue; waiting for a replug");
            u2f.stalled = true;
            stallReport.running = true;
        }
    }

    // The abort kills the hung PAM child, so the evidence is written to the journal first. The
    // script ends within 2 s; a replug meanwhile (stalled reset) already ended the attempt.
    Process {
        id: stallReport
        command: [Quickshell.shellPath("u2f-stall-report.sh")]
        onExited: exitCode => {
            if (exitCode !== 0)
                console.error("vekrona-lock: u2f-stall-report.sh exited with", exitCode);
            if (u2f.stalled && u2f.active)
                u2f.abort();
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
        // Sway ends the lock of a second client while another holds it, and of one that raced a dead locker's
        // disconnect: it sends `finished`, and the process would idle unlocked. Exit non-zero so systemd restarts it to
        // try again. Quickshell 0.3.1 clears `locked` then without a lockStateChanged, so `secure` is what tells.
        onSecureChanged: {
            if (secure) {
                setHint.running = true;
                notifyReady.running = true;
            } else if (!root.unlocking) {
                console.error("vekrona-lock: the compositor ended the session lock");
                Qt.exit(1);
            }
        }

        WlSessionLockSurface {
            color: VekronaTheme.dark.bg

            onVisibleChanged: field.forceActiveFocus()

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
                        text: root.pinExpected ? root.pinPrompt : root.passwordPrompt
                        color: VekronaTheme.dark.inkMuted
                    }

                    TextField {
                        id: field
                        // Twelve touch targets wide; tall enough for one body line plus the control padding.
                        width: 12 * VekronaTheme.sizeTarget
                        height: VekronaTheme.type.body.line + 2 * VekronaTheme.space3
                        padding: VekronaTheme.space3
                        colors: VekronaTheme.dark
                        fill: VekronaTheme.dark.surface2
                        borderColor: VekronaTheme.dark.lineStrong
                        echoMode: TextInput.Password
                        focus: true
                        placeholder: root.pinExpected ? "Tab: password instead" : root.passwordChosen ? "Tab: security key PIN instead" : ""

                        onActiveFocusChanged: {
                            if (!activeFocus)
                                forceActiveFocus();
                        }
                        onKeyPressed: event => {
                            if (event.key === Qt.Key_Tab) {
                                root.swapTarget();
                                event.accepted = true;
                                return;
                            }
                            root.keyPressed();
                        }
                        onTextEdited: root.fieldEdited(text)
                        onAccepted: {
                            root.submit(text);
                            root.fieldWasEmptied();
                            text = "";
                        }

                        Connections {
                            target: root
                            function onFieldsCleared() {
                                field.text = "";
                            }
                        }
                    }
                }

                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    // Fixed height so the layout does not jump when the line is empty.
                    width: field.width
                    height: Math.max(VekronaTheme.iconS, VekronaTheme.type.label.line)

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: VekronaTheme.space2

                        Pictogram {
                            visible: root.statusIcon !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            name: root.statusIcon
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

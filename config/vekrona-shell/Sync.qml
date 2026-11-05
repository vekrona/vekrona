import QtQuick
import QtQuick.Layouts
import "Vekrona"
import "."

BarPill {
    id: root

    required property var bar
    // The icon of each state of sync.json: the two round arrows of Material's `sync`, still when idle, turning while syncing,
    // with a warning mark when a folder has a problem and struck through when Syncthing cannot be reached.
    readonly property var icons: ({
            idle: "sync",
            syncing: "sync",
            problem: "sync_problem",
            offline: "sync_disabled"
        })
    // What the pill shows while sync.json is missing, unreadable or malformed (vekrona-sync is not running, or Syncthing is
    // not): the pill stays in the bar, since every bar slot is always there, and says so.
    readonly property var offlineReport: ({
            state: "offline",
            problem: null,
            me: null,
            folders: [],
            offers: [],
            nearby: [],
            pendingDevices: [],
            devices: [],
            arrivals: []
        })
    // The layout of sync.json that this file reads: SCHEMA_VERSION of bin/vekrona-sync, which tests/sync checks to be this number.
    readonly property int schemaVersion: 2
    // What the pill shows while the watcher runs code from before an update of the checkout (its sync.json has another schema).
    readonly property var outdatedReport: Object.assign({}, offlineReport, {
        state: "problem",
        problem: "The sync service is out of date. Run `systemctl --user restart vekrona-sync` or `./install.sh 50`."
    })
    // What vekrona-sync watch wrote, or offlineReport.
    readonly property var report: file.value
    readonly property int unseenArrivals: report.arrivals.filter(arrival => arrival.unseen).length
    // Nearby devices that answered and that the popout has not been open for since: the watcher sets and clears the flag.
    readonly property int unseenNearby: report.nearby.filter(device => device.unseen).length
    // The devices of the nearby list that are there now. Syncthing never forgets a device it heard once, so the list in sync.json
    // holds also those that have left; `vekrona-sync nearby` tries their addresses, once when the popout opens and again when the
    // list changes while it is open (a device that appears is announced on the network, which changes sync.json), and nothing
    // runs while the popout is shut. Empty from the opening until the answer, so that a device that left is never shown.
    property var nearbyReachable: []
    property var nearbyProbe: null
    readonly property var nearbyHere: report.nearby.filter(device => nearbyReachable.indexOf(device.id) >= 0)
    readonly property string nearbyIds: report.nearby.map(device => device.id).join(",")
    // Why the last command of the popout failed, "" while none did.
    property string failure: ""
    // Whether the popout shows how to pair a device that is not nearby.
    property bool pairing: false
    // The PNG of this computer's device ID, "" until vekrona-sync has made it.
    property string qrPath: ""
    // Why there is no QR code, "" while there is one or none was asked for. It is shown where the code would be, since the ID,
    // Copy ID and the field below it work without the code.
    property string qrFailure: ""
    property bool copied: false
    // The directory that the user chose to share, "" while none waits for its folder ID to be confirmed (the popout shows the
    // confirmation row while it is set), and why sharing it failed.
    property string sharePath: ""
    property string shareFailure: ""
    readonly property string shareName: sharePath.split("/").filter(part => part !== "").pop() ?? sharePath
    // The turn of the icon while syncing, in steps of a quarter of the half turn after which the glyph looks the same: one
    // timer wakeup per step, four a second, and nothing at all while no sync runs (an animation would redraw every frame) or
    // nobody is there to see it (Presence.qml: the screen is locked or off).
    property int spinStep: 0
    readonly property int spinSteps: 4

    // The folder's state in words.
    function folderStatus(folder): string {
        if (folder.state === "syncing")
            return "Syncing " + Math.round(folder.progress) + " %";
        if (folder.state === "problem")
            return "Problem: " + folder.problem;
        return "Up to date";
    }

    // Asks which of the nearby devices answer; the answer of an earlier, slower question is dropped.
    function probeNearby(): void {
        nearbyProbe?.kill();
        nearbyProbe = Exec.runOr(["vekrona-sync", "nearby"], stdout => nearbyReachable = stdout.split("\n").filter(line => line !== ""), reason => failure = reason);
    }

    // Runs a vekrona-sync command that the open popout shows the failure of.
    function run(args: list<string>): void {
        failure = "";
        Exec.runOr(["vekrona-sync"].concat(args), stdout => {}, reason => failure = reason);
    }

    // Runs a vekrona-sync command that opens a dialog of its own: the popout closes first, so that the dialog is not under
    // the Catcher, and a failure comes as a notification, like the keep-awake ones.
    function runClosing(args: list<string>): void {
        bar.openPopout = null;
        Exec.runOr(["vekrona-sync"].concat(args), stdout => {}, reason => Exec.check(["notify-send", "-a", "vekrona", "Sync", reason]));
    }

    // Shows or hides the pairing section; showing it makes the QR code of this computer's device ID.
    function setPairing(shown: bool): void {
        pairing = shown;
        copied = false;
        qrPath = "";
        qrFailure = "";
        if (shown)
            Exec.runOr(["vekrona-sync", "qr"], stdout => qrPath = stdout.trim(), reason => qrFailure = reason);
    }

    function pairPasted(): void {
        failure = "";
        Exec.runOr(["vekrona-sync", "pair", "--", pasteField.text], stdout => {
            pasteField.text = "";
            setPairing(false);
        }, reason => failure = reason);
    }

    // The portal's folder chooser, which opens over nothing, so the popout closes first. The popout then comes back for the
    // folder ID, set directly and not toggled: it is closed now, and a click on the pill meanwhile has its own say.
    function chooseFolder(): void {
        bar.openPopout = null;
        Exec.runOr(["vekrona-sync", "choose-folder"], stdout => {
            const path = stdout.replace(/\n$/, "");
            if (path !== "")
                confirmShare(path);
        }, reason => Exec.check(["notify-send", "-a", "vekrona", "Sync", reason]));
    }

    // The popout comes back with the suggested ID in the field, which has the keyboard: Enter shares and Esc cancels.
    function confirmShare(path: string): void {
        Exec.runOr(["vekrona-sync", "suggest-id", path], stdout => {
            shareFailure = "";
            sharePath = path;
            idField.text = stdout.trim();
            bar.openPopout = popout;
            idField.forceActiveFocus();
        }, reason => Exec.check(["notify-send", "-a", "vekrona", "Sync", reason]));
    }

    function shareConfirmed(): void {
        shareFailure = "";
        Exec.runOr(["vekrona-sync", "share", "--id=" + idField.text, sharePath], stdout => sharePath = "", reason => shareFailure = reason);
    }

    function open(path: string): void {
        bar.openPopout = null;
        Exec.detached(["xdg-open", path], Exec.home);
    }

    icon: icons[report.state]
    iconRotation: spinStep * 180 / spinSteps
    badgeCount: report.offers.length + report.pendingDevices.length + unseenArrivals + unseenNearby
    ariaName: "Sync, " + report.state
    onClicked: bar.togglePopout(popout)
    onNearbyIdsChanged: if (popout.open)
        probeNearby()

    Timer {
        interval: 250
        repeat: true
        running: root.report.state === "syncing" && Presence.here
        onTriggered: root.spinStep = (root.spinStep + 1) % root.spinSteps
        onRunningChanged: if (!running)
            root.spinStep = 0
    }

    StateFile {
        id: file
        path: StateDir.path + "/sync.json"
        absent: root.offlineReport
        parse: text => {
            const next = JSON.parse(text);
            if (next.schema !== root.schemaVersion) {
                console.error("sync.json has schema " + next.schema + " and this shell reads " + root.schemaVersion + ": vekrona-sync.service runs older code than the checkout, restart it");
                return root.outdatedReport;
            }
            if (!(next.state in root.icons))
                throw new Error("unknown state " + next.state);
            for (const key of ["folders", "offers", "nearby", "pendingDevices", "devices", "arrivals"])
                if (!Array.isArray(next[key]))
                    throw new Error(key + " is not a list");
            return next;
        }
    }

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        exclusiveKeyboard: root.sharePath !== ""
        onDismissed: root.bar.openPopout = null
        onOpenChanged: {
            root.failure = "";
            pasteField.text = "";
            if (!open)
                root.sharePath = "";
            root.pairing = false;
            root.nearbyReachable = [];
            if (open) {
                Exec.check(["vekrona-sync", "seen"]);
                root.probeNearby();
            }
        }

        ColumnLayout {
            Layout.preferredWidth: 24 * VekronaTheme.space4
            spacing: 0

            Label {
                visible: root.report.problem !== null || root.report.state === "offline"
                Layout.fillWidth: true
                Layout.leftMargin: VekronaTheme.space2
                wrapMode: Text.Wrap
                color: VekronaTheme.c.dangerInk
                style: VekronaTheme.type.body
                text: root.report.problem ?? "Syncthing is not reachable"
            }

            SyncSection {
                title: "Nearby"
                visible: root.nearbyHere.length > 0

                Repeater {
                    model: root.nearbyHere

                    SyncRow {
                        required property var modelData

                        icon: "wifi_tethering"
                        text: "Syncthing device " + modelData.code

                        BarPill {
                            value: "Pair"
                            ariaName: "Pair with Syncthing device " + modelData.code
                            onClicked: root.run(["pair", modelData.id])
                        }
                    }
                }
            }

            SyncSection {
                title: "New devices"
                visible: root.report.pendingDevices.length > 0

                Repeater {
                    model: root.report.pendingDevices

                    SyncRow {
                        required property var modelData

                        icon: "person_add"
                        text: modelData.name
                        detail: modelData.code

                        BarPill {
                            value: "Accept"
                            ariaName: "Accept " + modelData.name
                            onClicked: root.run(["accept", modelData.id])
                        }

                        BarPill {
                            value: "Reject"
                            ariaName: "Reject " + modelData.name
                            onClicked: root.run(["reject", modelData.id])
                        }
                    }
                }
            }

            SyncSection {
                title: "Offered to you"
                visible: root.report.offers.length > 0

                Repeater {
                    model: root.report.offers

                    SyncRow {
                        required property var modelData

                        icon: "folder_shared"
                        text: modelData.label
                        detail: "from " + modelData.deviceName

                        BarPill {
                            value: "Join"
                            ariaName: "Join " + modelData.label
                            onClicked: root.run(["join", modelData.folder])
                        }
                    }
                }
            }

            SyncSection {
                title: "Folders"
                visible: root.report.folders.length > 0

                Repeater {
                    model: root.report.folders

                    ColumnLayout {
                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 0

                        BarPill {
                            Layout.fillWidth: true
                            icon: "folder"
                            value: modelData.label
                            trailing: modelData.state === "problem" ? "" : root.folderStatus(modelData)
                            ariaName: "Open " + modelData.label + ", " + root.folderStatus(modelData)
                            onClicked: root.open(modelData.path)
                        }

                        Label {
                            visible: modelData.state === "problem"
                            Layout.fillWidth: true
                            Layout.leftMargin: VekronaTheme.space2
                            wrapMode: Text.Wrap
                            color: VekronaTheme.c.dangerInk
                            style: VekronaTheme.type.caption
                            text: root.folderStatus(modelData)
                        }
                    }
                }
            }

            SyncSection {
                title: "My devices"
                visible: root.report.devices.length > 0

                Repeater {
                    model: root.report.devices

                    ColumnLayout {
                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 0

                        SyncRow {
                            icon: "devices"
                            text: modelData.name
                            detail: modelData.connected ? "Online" : "Offline"

                            BarPill {
                                value: "Send file…"
                                ariaName: "Send a file to " + modelData.name
                                onClicked: root.runClosing(["send", modelData.id])
                            }
                        }

                        Label {
                            visible: modelData.connected && !modelData.sharesWithUs
                            Layout.fillWidth: true
                            Layout.leftMargin: VekronaTheme.space2
                            Layout.rightMargin: VekronaTheme.space2
                            wrapMode: Text.Wrap
                            color: VekronaTheme.c.inkMuted
                            style: VekronaTheme.type.caption
                            text: "Shares no folders with this computer yet. Share them from its Syncthing app."
                        }
                    }
                }
            }

            SyncSection {
                title: "Received"
                visible: root.report.arrivals.length > 0

                Repeater {
                    model: root.report.arrivals

                    BarPill {
                        required property var modelData

                        Layout.fillWidth: true
                        icon: "download"
                        value: modelData.name
                        trailing: "from " + modelData.from
                        ariaName: "Open " + modelData.name + ", from " + modelData.from
                        onClicked: root.open(modelData.path)
                    }
                }
            }

            BarPill {
                Layout.fillWidth: true
                Layout.topMargin: VekronaTheme.space2
                icon: "qr_code"
                value: "Pair another device…"
                emphasized: root.pairing
                ariaName: "Pair another device"
                onClicked: root.setPairing(!root.pairing)
            }

            ColumnLayout {
                visible: root.pairing
                Layout.fillWidth: true
                spacing: 0

                Label {
                    Layout.leftMargin: VekronaTheme.space2
                    Layout.topMargin: VekronaTheme.space2
                    style: VekronaTheme.type.caption
                    color: VekronaTheme.c.inkMuted
                    text: "This computer"
                }

                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: VekronaTheme.space2
                    Layout.rightMargin: VekronaTheme.space2
                    style: VekronaTheme.type.mono
                    font.family: VekronaTheme.fontMono
                    // Eight groups of seven, four to a line.
                    text: (root.report.me?.id ?? "").split("-").reduce((lines, group, index) => index === 4 ? lines + "\n" + group : lines + (index === 0 ? "" : "-") + group, "")
                }

                BarPill {
                    icon: "content_copy"
                    value: root.copied ? "Copied" : "Copy ID"
                    widestValue: ["Copy ID", "Copied"]
                    ariaName: "Copy this computer's device ID"
                    onClicked: Exec.copy(root.report.me.id, () => root.copied = true)
                }

                Image {
                    visible: root.qrPath !== ""
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: VekronaTheme.space2
                    // The PNG has 8 pixels to a module of the code; half of it keeps every module 4 whole pixels wide.
                    Layout.preferredWidth: implicitWidth / 2
                    Layout.preferredHeight: implicitHeight / 2
                    cache: false
                    smooth: false
                    source: root.qrPath === "" ? "" : "file://" + root.qrPath
                    Accessible.role: Accessible.Graphic
                    Accessible.name: "QR code of this computer's device ID"
                }

                Label {
                    visible: root.qrFailure !== ""
                    Layout.fillWidth: true
                    Layout.leftMargin: VekronaTheme.space2
                    Layout.rightMargin: VekronaTheme.space2
                    Layout.topMargin: VekronaTheme.space2
                    wrapMode: Text.Wrap
                    color: VekronaTheme.c.dangerInk
                    style: VekronaTheme.type.body
                    text: root.qrFailure
                }

                Label {
                    Layout.leftMargin: VekronaTheme.space2
                    Layout.topMargin: VekronaTheme.space2
                    style: VekronaTheme.type.caption
                    color: VekronaTheme.c.inkMuted
                    text: "The other device's ID"
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: VekronaTheme.space1

                    TextField {
                        id: pasteField
                        Layout.fillWidth: true
                        placeholder: "Paste a device ID"
                        accessibleName: "Device ID of the other device"
                        onAccepted: root.pairPasted()
                    }

                    BarPill {
                        value: "Pair"
                        ariaName: "Pair with the pasted device ID"
                        onClicked: root.pairPasted()
                    }
                }
            }

            SyncSection {
                title: "New folder"
                visible: root.sharePath !== ""

                SyncRow {
                    icon: "folder"
                    text: root.shareName
                }

                Label {
                    Layout.leftMargin: VekronaTheme.space2
                    style: VekronaTheme.type.caption
                    color: VekronaTheme.c.inkMuted
                    text: "Folder ID, fixed once shared"
                }

                TextField {
                    id: idField
                    Layout.fillWidth: true
                    placeholder: "Folder ID"
                    accessibleName: "Folder ID"
                    onAccepted: root.shareConfirmed()
                }

                Label {
                    visible: root.shareFailure !== ""
                    Layout.fillWidth: true
                    Layout.leftMargin: VekronaTheme.space2
                    Layout.topMargin: VekronaTheme.space1
                    wrapMode: Text.Wrap
                    color: VekronaTheme.c.dangerInk
                    style: VekronaTheme.type.body
                    text: root.shareFailure
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: VekronaTheme.space1

                    BarPill {
                        value: "Share"
                        emphasized: true
                        ariaName: "Share the folder under this ID"
                        onClicked: root.shareConfirmed()
                    }

                    BarPill {
                        value: "Cancel"
                        ariaName: "Do not share the folder"
                        onClicked: root.sharePath = ""
                    }
                }
            }

            BarPill {
                Layout.fillWidth: true
                Layout.topMargin: VekronaTheme.space2
                icon: "create_new_folder"
                value: "Share a folder…"
                ariaName: "Share a folder"
                onClicked: root.chooseFolder()
            }

            Label {
                visible: root.failure !== ""
                Layout.fillWidth: true
                Layout.leftMargin: VekronaTheme.space2
                wrapMode: Text.Wrap
                color: VekronaTheme.c.dangerInk
                style: VekronaTheme.type.body
                text: root.failure
            }
        }
    }
}

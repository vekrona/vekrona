import QtQuick
import QtQuick.Layouts
import "Vekrona"
import "."

BarPill {
    id: root

    required property var bar
    // The icon of each state of sync.json.
    readonly property var icons: ({
            idle: "cloud_done",
            syncing: "sync",
            problem: "sync_problem",
            offline: "cloud_off"
        })
    // What the pill shows while sync.json is missing, unreadable or malformed (vekrona-sync is not running, or Syncthing is
    // not): the pill stays in the bar, since every bar slot is always there, and says so.
    readonly property var offlineReport: ({
            state: "offline",
            problem: null,
            folders: [],
            offers: [],
            pendingDevices: [],
            devices: [],
            arrivals: []
        })
    // What vekrona-sync watch wrote, or offlineReport.
    readonly property var report: file.value
    readonly property int unseenArrivals: report.arrivals.filter(arrival => arrival.unseen).length
    // Why the last command of the popout failed, "" while none did.
    property string failure: ""

    // The folder's state in words.
    function folderStatus(folder): string {
        if (folder.state === "syncing")
            return "Syncing " + Math.round(folder.progress) + " %";
        if (folder.state === "problem")
            return "Problem: " + folder.problem;
        return "Up to date";
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

    function open(path: string): void {
        bar.openPopout = null;
        Exec.detached(["xdg-open", path], Exec.home);
    }

    icon: icons[report.state]
    badgeCount: report.offers.length + report.pendingDevices.length + unseenArrivals
    ariaName: "Sync, " + report.state
    onClicked: bar.togglePopout(popout)

    StateFile {
        id: file
        path: StateDir.path + "/sync.json"
        absent: root.offlineReport
        parse: text => {
            const next = JSON.parse(text);
            if (!(next.state in root.icons))
                throw new Error("unknown state " + next.state);
            for (const key of ["folders", "offers", "pendingDevices", "devices", "arrivals"])
                if (!Array.isArray(next[key]))
                    throw new Error(key + " is not a list");
            return next;
        }
    }

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null
        onOpenChanged: {
            root.failure = "";
            if (open)
                Exec.check(["vekrona-sync", "seen"]);
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
                title: "My devices"
                visible: root.report.devices.length > 0

                Repeater {
                    model: root.report.devices

                    SyncRow {
                        required property var modelData

                        icon: "devices"
                        text: modelData.name
                        detail: modelData.connected ? "Online" : "Offline"

                        BarPill {
                            value: "Send file…"
                            ariaName: "Send a file to " + modelData.name
                            onClicked: root.runClosing(["send", modelData.id])
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
                icon: "create_new_folder"
                value: "Share a folder…"
                ariaName: "Share a folder"
                onClicked: root.runClosing(["share"])
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

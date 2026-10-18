import QtQuick
import QtQuick.Layouts
import "Vekrona"
import "."

BarPill {
    id: root

    required property var bar
    // Which part is open under its row: "date" (the until day's month grid), "download", "process", or "" for none.
    property string expanded: ""
    // The rows of the open list; null until they are read.
    property var choices: null
    // Why the open list could not be read, "" while it can.
    property string choicesFailure: ""
    property var listing: null

    // The arguments of a vekrona-caffeine command. Untyped: a typed list<string> parameter receives an empty list from the
    // arguments of a picked row, which come through a `var` signal parameter.
    function begin(args): void {
        Caffeine.start(args, Caffeine.notify);
        bar.openPopout = null;
    }

    function stopListing(): void {
        listing?.kill();
        listing = null;
        choices = null;
        choicesFailure = "";
        expanded = "";
    }

    // Opens the list `kind` reads, or closes it when it is open already. At most one list is open.
    function toggleList(kind: string, read): void {
        const closing = expanded === kind;
        stopListing();
        if (closing)
            return;
        expanded = kind;
        listing = read(rows => {
            listing = null;
            choices = rows;
        }, reason => {
            listing = null;
            choicesFailure = reason;
        });
    }

    icon: "local_cafe"
    emphasized: Caffeine.active
    ariaName: Caffeine.active ? "Keep awake, " + Caffeine.target : "Keep awake"
    onClicked: bar.togglePopout(popout)

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null
        onOpenChanged: {
            root.stopListing();
            if (open)
                until.reset();
        }

        ColumnLayout {
            Layout.preferredWidth: 20 * VekronaTheme.space4
            spacing: 0

            BarPill {
                visible: Caffeine.active
                Layout.fillWidth: true
                icon: "stop_circle"
                value: "End session · " + Caffeine.target + (Caffeine.remaining !== "" ? " · " + Caffeine.remaining : "")
                ariaName: "End the keep-awake session, " + Caffeine.target
                onClicked: {
                    Caffeine.stop(Caffeine.notify);
                    root.bar.openPopout = null;
                }
            }

            Rule {
                visible: Caffeine.active
            }

            Label {
                Layout.leftMargin: VekronaTheme.space2
                style: VekronaTheme.type.caption
                color: VekronaTheme.c.inkMuted
                text: "Stay awake for"
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 0

                Repeater {
                    model: Caffeine.presets

                    BarPill {
                        required property string modelData

                        Layout.fillWidth: true
                        value: modelData
                        emphasized: Caffeine.kind === "for" && Caffeine.preset === modelData
                        ariaName: "Stay awake for " + modelData
                        onClicked: root.begin(["for", modelData])
                    }
                }
            }

            Label {
                Layout.leftMargin: VekronaTheme.space2
                Layout.topMargin: VekronaTheme.space2
                style: VekronaTheme.type.caption
                color: VekronaTheme.c.inkMuted
                text: "Stay awake until"
            }

            CaffeineUntil {
                id: until
                Layout.fillWidth: true
                open: popout.open
                picking: root.expanded === "date"
                onPickerRequested: shown => {
                    root.stopListing();
                    if (shown)
                        root.expanded = "date";
                }
                onPicked: stamp => root.begin(["until", stamp])
            }

            Rule {}

            BarPill {
                Layout.fillWidth: true
                icon: root.expanded === "download" ? "expand_more" : "chevron_right"
                value: "Wait for download"
                emphasized: root.expanded === "download"
                ariaName: "Wait for download"
                onClicked: root.toggleList("download", Caffeine.downloads)
            }

            CaffeineChoices {
                visible: root.expanded === "download"
                Layout.fillWidth: true
                choices: root.choices
                failure: root.choicesFailure
                emptyText: "No active downloads"
                onPicked: args => root.begin(args)
            }

            BarPill {
                Layout.fillWidth: true
                icon: root.expanded === "process" ? "expand_more" : "chevron_right"
                value: "Wait for process"
                emphasized: root.expanded === "process"
                ariaName: "Wait for process"
                onClicked: root.toggleList("process", Caffeine.apps)
            }

            CaffeineChoices {
                visible: root.expanded === "process"
                Layout.fillWidth: true
                choices: root.choices
                failure: root.choicesFailure
                emptyText: "No windows"
                onPicked: args => root.begin(args)
            }
        }
    }
}

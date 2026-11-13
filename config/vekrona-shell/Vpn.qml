import QtQuick
import QtQuick.Layouts
import "Vekrona"
import "."

BarPill {
    id: root

    required property var bar
    // The icon of each level of the popout's tree.
    readonly property var levelIcons: ({
            vendor: "dns",
            country: "public",
            configuration: "vpn_key"
        })

    // Why the last command of the popout failed, "" while none did.
    property string failure: ""
    // Where the popout is in the tree vendor > country > configuration: "" at the top, the vendor's id, then the country's code.
    property string vendorId: ""
    property string countryCode: ""
    // The configuration waiting for the confirmation of its removal, or null.
    property var forgetTarget: null

    readonly property var vendor: VpnState.catalog.find(candidate => candidate.id === vendorId) ?? null
    readonly property var country: vendor?.countries.find(candidate => candidate.code === countryCode) ?? null
    // 0 at the vendors, 1 in a vendor, 2 in a country.
    readonly property int level: vendor === null ? 0 : country === null ? 1 : 2
    // The account field is shown, and so takes the keyboard without a click: the popout asks for typing then.
    readonly property bool loginShown: VpnState.needsLogin(vendorId)
    // The rows of the level the popout is at.
    readonly property var rows: level === 0 ? vendorRows() : level === 1 ? countryRows() : configurationRows()
    readonly property string backLabel: level === 2 ? country.name : vendor?.label ?? ""

    // Runs a vekrona-vpn command that the open popout shows the failure of.
    function run(args: list<string>, onOk): void {
        failure = "";
        VpnState.command(args, stdout => onOk?.(), reason => failure = reason);
    }

    // Runs a vekrona-vpn command that may open a dialog of its own or a keyring prompt (connect, forget, import): the popout
    // closes first, so that the dialog is not under the Catcher and the prompt gets the keyboard, and a failure comes as a
    // notification, like the keep-awake ones.
    function runClosing(args: list<string>): void {
        bar.openPopout = null;
        VpnState.command(args, stdout => {}, reason => Exec.check(["notify-send", "-a", "vekrona", "VPN", reason]));
    }

    // Stores the account number in the keyring, which may prompt: the popout closes first, as runClosing does.
    function logIn(): void {
        const account = accountField.text.trim();
        if (account === "")
            return;
        bar.openPopout = null;
        VpnState.logIn(account, () => {}, reason => Exec.check(["notify-send", "-a", "vekrona", "VPN", reason]));
    }

    function forget(): void {
        const uuid = forgetTarget.uuid;
        forgetTarget = null;
        runClosing(["forget", uuid]);
    }

    // Whether the tunnel of the row's connection is the one that is up or coming up.
    function isCurrent(match: var): bool {
        const connection = VpnState.status.connection;
        return connection !== null && VpnState.status.tunnel !== "down" && match(connection);
    }

    function vendorRows(): var {
        return VpnState.catalog.map(entry => ({
                    key: entry.id,
                    icon: levelIcons.vendor,
                    label: entry.label,
                    trailing: VpnState.needsLogin(entry.id) ? "Not logged in" : entry.countries.length + (entry.countries.length === 1 ? " country" : " countries"),
                    emphasized: isCurrent(connection => connection.vendor === entry.id),
                    ariaName: "Open " + entry.label,
                    forgettable: false,
                    activate: () => vendorId = entry.id
                }));
    }

    function countryRows(): var {
        if (loginShown)
            return [];
        return vendor.countries.map(entry => {
            const choices = VpnState.connectChoices(vendor, entry);
            const single = choices.length === 1;
            const forgettable = single && choices[0].uuid !== null;
            return {
                key: entry.code,
                icon: levelIcons.country,
                label: entry.name,
                trailing: single ? choices[0].detail : choices.length + " configurations",
                emphasized: isCurrent(connection => connection.vendor === vendor.id && connection.country === entry.code),
                ariaName: (single ? "Connect to " : "Open ") + entry.name,
                forgettable: forgettable,
                forgetUuid: forgettable ? choices[0].uuid : "",
                forgetName: forgettable ? choices[0].name : "",
                activate: single ? () => runClosing(choices[0].args) : () => countryCode = entry.code
            };
        });
    }

    function configurationRows(): var {
        return VpnState.connectChoices(vendor, country).map(choice => ({
                    key: choice.key,
                    icon: levelIcons.configuration,
                    label: choice.name,
                    trailing: "",
                    emphasized: isCurrent(connection => connection.uuid === choice.uuid),
                    ariaName: "Connect with " + choice.name,
                    forgettable: true,
                    forgetUuid: choice.uuid,
                    forgetName: choice.name,
                    activate: () => runClosing(choice.args)
                }));
    }

    function back(): void {
        forgetTarget = null;
        if (level === 2)
            countryCode = "";
        else
            vendorId = "";
    }

    icon: VpnState.look.icon
    filled: VpnState.phase === "on"
    ariaName: "VPN, " + VpnState.look.text
    onClicked: bar.togglePopout(popout)
    onLoginShownChanged: if (loginShown)
        accountField.forceActiveFocus()

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        exclusiveKeyboard: root.loginShown
        // Esc steps back out of a vendor or a country, wherever the focus is (after a click it is parked, outside the column); at
        // the top it closes the popout.
        onDismissed: {
            if (root.level > 0)
                root.back();
            else
                root.bar.openPopout = null;
        }
        onOpenChanged: {
            root.failure = "";
            root.vendorId = "";
            root.countryCode = "";
            root.forgetTarget = null;
            accountField.text = "";
            if (open) {
                VpnState.refresh();
                VpnState.loadList();
            }
        }

        PopoutColumn {
            PopoutRow {
                icon: VpnState.look.icon
                text: VpnState.look.text

                BarPill {
                    visible: VpnState.status.armed || VpnState.status.tunnel !== "down"
                    icon: "power_settings_new"
                    value: "Off"
                    ariaName: "Turn the VPN off"
                    onClicked: root.run(["off"])
                }
            }

            VpnNote {
                text: VpnState.connectionLabel
            }

            VpnNote {
                text: VpnState.look.detail
            }

            VpnNote {
                danger: true
                text: VpnState.unknownReason
            }

            BarPill {
                visible: root.level > 0
                Layout.fillWidth: true
                Layout.topMargin: VekronaTheme.space2
                icon: "arrow_back"
                value: root.backLabel
                ariaName: "Back from " + root.backLabel
                onClicked: root.back()
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: root.level > 0 ? 0 : VekronaTheme.space2
                spacing: 0

                Repeater {
                    model: root.rows

                    RowLayout {
                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 0

                        BarPill {
                            Layout.fillWidth: true
                            icon: modelData.icon
                            value: modelData.label
                            trailing: modelData.trailing
                            emphasized: modelData.emphasized
                            ariaName: modelData.ariaName
                            onClicked: modelData.activate()
                        }

                        BarPill {
                            visible: modelData.forgettable
                            icon: "link_off"
                            ariaName: "Forget " + (modelData.forgetName ?? "")
                            onClicked: root.forgetTarget = {
                                uuid: modelData.forgetUuid,
                                name: modelData.forgetName
                            }
                        }
                    }
                }
            }

            VpnNote {
                danger: true
                text: VpnState.listFailure
            }

            PopoutSection {
                title: "Mullvad account number"
                visible: root.loginShown

                TextField {
                    id: accountField
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    placeholder: "Account number"
                    accessibleName: "Mullvad account number"
                    onAccepted: root.logIn()
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: VekronaTheme.space1

                    BarPill {
                        enabled: accountField.text.trim() !== ""
                        icon: "login"
                        value: "Log in"
                        emphasized: true
                        ariaName: "Log in to Mullvad"
                        onClicked: root.logIn()
                    }
                }
            }

            PopoutSection {
                title: "Forget this configuration?"
                visible: root.forgetTarget !== null
                onVisibleChanged: if (visible)
                    cancelForget.forceActiveFocus()

                PopoutRow {
                    icon: "vpn_key"
                    text: root.forgetTarget?.name ?? ""
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: VekronaTheme.space1

                    BarPill {
                        value: "Forget"
                        emphasized: true
                        ariaName: "Forget " + (root.forgetTarget?.name ?? "")
                        onClicked: root.forget()
                    }

                    BarPill {
                        id: cancelForget
                        value: "Cancel"
                        ariaName: "Keep the configuration"
                        onClicked: root.forgetTarget = null
                    }
                }
            }

            BarPill {
                Layout.fillWidth: true
                Layout.topMargin: VekronaTheme.space2
                icon: "upload_file"
                value: "Import Proton…"
                ariaName: "Import a Proton configuration"
                onClicked: root.runClosing(["import", "--vendor", "proton"])
            }

            BarPill {
                Layout.fillWidth: true
                icon: "upload_file"
                value: "Import other…"
                ariaName: "Import a configuration of another provider"
                onClicked: root.runClosing(["import", "--vendor", "other"])
            }

            VpnNote {
                Layout.topMargin: VekronaTheme.space1
                danger: true
                text: root.failure
            }
        }
    }
}

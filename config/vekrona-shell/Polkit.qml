import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Polkit
import "Vekrona"

PanelWindow {
    id: root

    readonly property AuthFlow flow: agent.flow
    readonly property int panelWidth: 12 * VekronaTheme.sizeTarget
    readonly property string currentUser: Quickshell.env("USER")
    readonly property bool currentUserListed: (flow?.identities ?? []).some(identity => !identity.isGroup && identity.string === currentUser)
    readonly property string identityNote: !flow?.selectedIdentity ? "" : (currentUserListed ? "" : currentUser + " may not authenticate this request. ") + "Account: " + flow.selectedIdentity.string
    readonly property string waitingNote: "Waiting for the system to ask for your password. A security key or fingerprint check may come first."
    readonly property string statusText: {
        if (!flow || flow.isCompleted)
            return "";
        if (flow.isResponseRequired)
            return flow.inputPrompt.trim() || "Password:";
        const info = flow.supplementaryIsError ? "" : flow.supplementaryMessage;
        return info || waitingNote;
    }
    property bool attempted: false

    function selectCurrentUser(): void {
        const identities = flow.identities;
        if (identities.length < 2)
            return;
        const current = identities.find(identity => !identity.isGroup && identity.string === currentUser);
        if (current && current !== flow.selectedIdentity)
            flow.selectedIdentity = current;
    }

    function submit(): void {
        if (!flow.isResponseRequired)
            return;
        attempted = true;
        flow.submit(password.text);
        password.text = "";
    }

    function cancel(): void {
        flow.cancelAuthenticationRequest();
    }

    visible: agent.isActive
    // The window is the dialog and nothing else: opaque, and centred by the compositor because it has no anchors.
    // The keyboard stays grabbed (Exclusive) until Escape or Cancel: losing focus must not cancel a password prompt.
    color: VekronaTheme.c.surface1
    implicitWidth: panelWidth
    implicitHeight: column.implicitHeight + 2 * VekronaTheme.space4
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "vekrona-polkit"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    PolkitAgent {
        id: agent
        onAuthenticationRequestStarted: {
            root.attempted = false;
            password.text = "";
            root.selectCurrentUser();
            password.forceActiveFocus();
        }
    }

    Connections {
        target: root.flow
        enabled: root.flow !== null

        function onIsResponseRequiredChanged() {
            if (root.flow.isResponseRequired)
                password.forceActiveFocus();
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: VekronaTheme.borderHair
        border.color: VekronaTheme.c.line

        FocusScope {
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.cancel()

            ColumnLayout {
                id: column
                anchors.fill: parent
                anchors.margins: VekronaTheme.space4
                spacing: VekronaTheme.space3

                Label {
                    Layout.fillWidth: true
                    style: VekronaTheme.type.title
                    text: "Authentication required"
                }

                Label {
                    Layout.fillWidth: true
                    style: VekronaTheme.type.body
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    text: root.flow?.message ?? ""
                }

                Label {
                    visible: text !== ""
                    Layout.fillWidth: true
                    style: VekronaTheme.type.body
                    color: VekronaTheme.c.inkMuted
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    text: root.identityNote
                }

                Label {
                    Layout.fillWidth: true
                    style: VekronaTheme.type.body
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    text: root.statusText
                }

                TextField {
                    id: password
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    enabled: root.flow?.isResponseRequired ?? false
                    focus: true
                    accessibleName: root.statusText
                    onAccepted: root.submit()
                }

                Label {
                    visible: text !== ""
                    Layout.fillWidth: true
                    style: VekronaTheme.type.body
                    color: VekronaTheme.c.dangerInk
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    text: root.flow?.supplementaryIsError ? root.flow.supplementaryMessage : root.attempted && root.flow?.failed ? "Authentication failed. Try again." : ""
                }

                RowLayout {
                    Layout.alignment: Qt.AlignRight
                    spacing: VekronaTheme.space2

                    BarPill {
                        value: "Cancel"
                        ariaName: "Cancel authentication"
                        onClicked: root.cancel()
                    }

                    BarPill {
                        value: "Authenticate"
                        emphasized: true
                        ariaName: "Authenticate"
                        onClicked: root.submit()
                    }
                }
            }
        }
    }
}

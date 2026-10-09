import QtQuick
import QtQuick.Layouts
import Quickshell.Networking
import "Vekrona"
import "."

BarPill {
    id: root

    required property var bar
    property var passwordFor: null
    property string failure: ""

    function connectionFailed(network, reason): void {
        failure = Wireless.failureText(network, reason);
        console.error("Wi-Fi " + failure);
        if (network.security !== WifiSecurityType.Open) {
            passwordFor = network;
            password.forceActiveFocus();
        }
    }

    function chooseNetwork(network): void {
        failure = "";
        if (Wireless.needsPassword(network)) {
            passwordFor = network;
            password.forceActiveFocus();
        } else {
            Wireless.toggleConnection(network);
        }
    }

    icon: Wireless.wired ? "lan" : Wireless.connectedWifi ? Wireless.wifiGlyph(Wireless.connectedWifi.signalStrength) : "wifi_off"
    ariaName: "Network"
    onClicked: bar.togglePopout(popout)

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null
        onOpenChanged: if (!open) {
            root.passwordFor = null;
            root.failure = "";
        }

        Repeater {
            model: Wireless.wifiNetworks

            BarPill {
                required property var modelData

                Layout.fillWidth: true
                icon: Wireless.wifiGlyph(modelData.signalStrength)
                value: modelData.name
                emphasized: modelData.connected
                ariaName: "Wi-Fi " + modelData.name
                onClicked: root.chooseNetwork(modelData)

                Connections {
                    target: modelData
                    function onConnectionFailed(reason): void {
                        root.connectionFailed(modelData, reason);
                    }
                }
            }
        }

        Label {
            visible: root.failure !== ""
            Layout.maximumWidth: VekronaTheme.sizeTarget * 8
            wrapMode: Text.Wrap
            color: VekronaTheme.c.dangerInk
            style: VekronaTheme.type.body
            text: root.failure
        }

        Rectangle {
            visible: root.passwordFor !== null
            Layout.fillWidth: true
            implicitHeight: VekronaTheme.sizeTarget
            color: "transparent"
            border.width: VekronaTheme.borderControl
            border.color: VekronaTheme.c.line

            TextInput {
                id: password
                anchors.fill: parent
                anchors.margins: VekronaTheme.space2
                verticalAlignment: TextInput.AlignVCenter
                echoMode: TextInput.Password
                color: VekronaTheme.c.ink
                font.family: VekronaTheme.fontSans
                font.pixelSize: VekronaTheme.type.body.size
                Accessible.name: "Wi-Fi password"
                onAccepted: {
                    root.passwordFor.connectWithPsk(text);
                    text = "";
                    root.passwordFor = null;
                }
            }
        }

        Rectangle {
            visible: Wireless.adapter !== null
            Layout.fillWidth: true
            implicitHeight: VekronaTheme.borderHair
            color: VekronaTheme.c.line
        }

        BarPill {
            visible: Wireless.adapter !== null
            Layout.fillWidth: true
            icon: Wireless.bluetoothEnabled ? "bluetooth" : "bluetooth_disabled"
            value: "Bluetooth"
            emphasized: Wireless.bluetoothEnabled
            ariaName: "Bluetooth power"
            onClicked: Wireless.toggleBluetooth()
        }

        Repeater {
            model: Wireless.pairedDevices

            BarPill {
                required property var modelData

                Layout.fillWidth: true
                icon: modelData.connected ? "bluetooth_connected" : "bluetooth"
                value: modelData.name
                emphasized: modelData.connected
                ariaName: "Bluetooth " + modelData.name
                onClicked: modelData.connected ? modelData.disconnect() : modelData.connect()
            }
        }
    }
}

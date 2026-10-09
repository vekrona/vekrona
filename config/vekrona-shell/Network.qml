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
    property string bluetoothFailure: ""

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
        onOpenChanged: {
            // A pairing can end after the popout closed: its failure must not greet the next opening.
            root.bluetoothFailure = "";
            if (open)
                return;
            root.passwordFor = null;
            root.failure = "";
            Wireless.setScanning(false);
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
            value: Wireless.bluetoothBlocked ? "Bluetooth blocked" : "Bluetooth"
            emphasized: Wireless.bluetoothEnabled
            ariaName: Wireless.bluetoothBlocked ? "Bluetooth power, blocked by rfkill" : "Bluetooth power"
            onClicked: {
                root.bluetoothFailure = "";
                Wireless.toggleBluetooth(reason => root.bluetoothFailure = reason);
            }
        }

        Repeater {
            model: Wireless.pairedDevices

            RowLayout {
                required property var modelData

                Layout.fillWidth: true
                spacing: 0

                BarPill {
                    Layout.fillWidth: true
                    icon: modelData.connected ? "bluetooth_connected" : "bluetooth"
                    value: modelData.name
                    emphasized: modelData.connected
                    ariaName: "Bluetooth " + modelData.name
                    onClicked: modelData.connected ? modelData.disconnect() : modelData.connect()
                }

                BarPill {
                    icon: "link_off"
                    ariaName: "Forget " + modelData.name
                    onClicked: Wireless.forgetDevice(modelData)
                }
            }
        }

        BarPill {
            visible: Wireless.bluetoothEnabled
            Layout.fillWidth: true
            icon: "bluetooth_searching"
            value: Wireless.scanning ? "Searching for devices" : "Pair new device"
            emphasized: Wireless.scanning
            ariaName: "Pair new device"
            onClicked: {
                root.bluetoothFailure = "";
                Wireless.setScanning(!Wireless.scanning);
            }
        }

        Repeater {
            model: Wireless.scanning ? Wireless.unpairedDevices : []

            BarPill {
                required property var modelData

                Layout.fillWidth: true
                icon: modelData.pairing ? "sync" : "bluetooth"
                value: modelData.pairing ? modelData.name + ", pairing" : modelData.name
                emphasized: modelData.pairing
                ariaName: "Pair " + modelData.name
                onClicked: {
                    root.bluetoothFailure = "";
                    Wireless.pairDevice(modelData, reason => root.bluetoothFailure = reason);
                }
            }
        }

        Label {
            visible: root.bluetoothFailure !== ""
            Layout.maximumWidth: VekronaTheme.sizeTarget * 8
            wrapMode: Text.Wrap
            color: VekronaTheme.c.dangerInk
            style: VekronaTheme.type.body
            text: root.bluetoothFailure
        }
    }
}

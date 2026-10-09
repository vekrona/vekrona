import QtQuick
import QtQuick.Layouts
import Quickshell.Bluetooth
import Quickshell.Networking
import "Vekrona"

BarPill {
    id: root

    required property var bar
    readonly property var devices: Networking.devices.values
    readonly property var wifiNetworks: devices
        .filter(device => device.type === DeviceType.Wifi)
        .reduce((all, device) => all.concat(device.networks.values), [])
        .sort((a, b) => b.signalStrength - a.signalStrength)
    readonly property bool wired: devices.some(device => device.type === DeviceType.Wired && device.connected)
    readonly property var connectedWifi: wifiNetworks.find(network => network.connected) ?? null
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var pairedDevices: adapter ? adapter.devices.values.filter(device => device.paired) : []
    property var passwordFor: null

    function wifiGlyph(strength: real): string {
        return strength >= 0.66 ? "wifi" : strength >= 0.33 ? "wifi_2_bar" : "wifi_1_bar";
    }

    function chooseNetwork(network): void {
        if (network.connected) {
            network.disconnect();
        } else if (network.known || network.security === WifiSecurityType.Open) {
            network.connect();
        } else {
            passwordFor = network;
            password.forceActiveFocus();
        }
    }

    icon: wired ? "lan" : connectedWifi ? wifiGlyph(connectedWifi.signalStrength) : "wifi_off"
    ariaName: "Network"
    onClicked: bar.togglePopout(popout)

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null
        onOpenChanged: if (!open) root.passwordFor = null

        Repeater {
            model: root.wifiNetworks

            BarPill {
                required property var modelData

                Layout.fillWidth: true
                icon: root.wifiGlyph(modelData.signalStrength)
                value: modelData.name
                emphasized: modelData.connected
                ariaName: "Wi-Fi " + modelData.name
                onClicked: root.chooseNetwork(modelData)
            }
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
            visible: root.adapter !== null
            Layout.fillWidth: true
            implicitHeight: VekronaTheme.borderHair
            color: VekronaTheme.c.line
        }

        BarPill {
            visible: root.adapter !== null
            Layout.fillWidth: true
            icon: root.adapter?.enabled ? "bluetooth" : "bluetooth_disabled"
            value: "Bluetooth"
            emphasized: root.adapter?.enabled ?? false
            ariaName: "Bluetooth power"
            onClicked: root.adapter.enabled = !root.adapter.enabled
        }

        Repeater {
            model: root.pairedDevices

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

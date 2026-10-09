pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Networking

// The Wi-Fi and Bluetooth state of the machine and the actions on it, shared by
// the bar's network popout and the launcher's settings.
Singleton {
    id: root

    readonly property var devices: Networking.devices.values
    readonly property var wifiNetworks: devices
        .filter(device => device.type === DeviceType.Wifi)
        .reduce((all, device) => all.concat(device.networks.values), [])
        .sort((a, b) => b.signalStrength - a.signalStrength)
    readonly property bool wired: devices.some(device => device.type === DeviceType.Wired && device.connected)
    readonly property var connectedWifi: wifiNetworks.find(network => network.connected) ?? null
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var pairedDevices: adapter ? adapter.devices.values.filter(device => device.paired) : []
    readonly property bool wifiEnabled: Networking.wifiEnabled
    readonly property bool bluetoothEnabled: adapter?.enabled ?? false

    function wifiGlyph(strength: real): string {
        return strength >= 0.66 ? "wifi" : strength >= 0.33 ? "wifi_2_bar" : "wifi_1_bar";
    }

    function failureText(network, reason): string {
        return network.name + ": " + ConnectionFailReason.toString(reason);
    }

    // True when connecting to the network takes a password the user has not given yet.
    function needsPassword(network): bool {
        return !network.connected && !network.known && network.security !== WifiSecurityType.Open;
    }

    function toggleConnection(network): void {
        if (network.connected)
            network.disconnect();
        else
            network.connect();
    }

    // A toggle returns "" when it switched, else the reason it could not.
    function refuse(reason: string): string {
        console.error("Wireless: " + reason);
        return reason;
    }

    function toggleWifi(): string {
        if (!Networking.wifiHardwareEnabled)
            return refuse("Wi-Fi is switched off by a hardware switch");
        Networking.wifiEnabled = !Networking.wifiEnabled;
        return "";
    }

    function toggleBluetooth(): string {
        if (!adapter)
            return refuse("there is no Bluetooth adapter");
        adapter.enabled = !adapter.enabled;
        return "";
    }
}

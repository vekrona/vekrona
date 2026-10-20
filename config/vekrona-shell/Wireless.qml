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
    // Strongest first. A signal moves the order of the list on every reading, so a view of it must follow by object (a
    // ScriptModel), which moves the rows of the networks instead of building them again; equal signals keep a stable order.
    readonly property var wifiNetworks: devices
        .filter(device => device.type === DeviceType.Wifi)
        .reduce((all, device) => all.concat(device.networks.values), [])
        .sort((a, b) => b.signalStrength - a.signalStrength || a.name.localeCompare(b.name))
    readonly property bool wired: devices.some(device => device.type === DeviceType.Wired && device.connected)
    readonly property var connectedWifi: wifiNetworks.find(network => network.connected) ?? null
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var pairedDevices: adapter ? adapter.devices.values.filter(device => device.paired) : []
    // Discovered devices that broadcast a name; the ones without are only an address, nothing to choose by.
    readonly property var unpairedDevices: adapter ? adapter.devices.values.filter(device => !device.paired && device.deviceName !== "") : []
    readonly property bool wifiEnabled: Networking.wifiEnabled
    readonly property bool bluetoothEnabled: adapter?.enabled ?? false
    // Bluetooth is switched off by rfkill: toggleBluetooth lifts that before it powers the adapter.
    readonly property bool bluetoothBlocked: adapter?.state === BluetoothAdapterState.Blocked
    readonly property bool scanning: adapter?.discovering ?? false
    // Set once rfkill is unblocked, until BlueZ reports the adapter unblocked and it can be powered, or the adapter is gone.
    property bool enableOnUnblock: false

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

    // Calls fail(reason) when a Bluetooth action does not take: the callers show the reason, each in its place.
    function toggleBluetooth(fail): void {
        if (!adapter) {
            fail(refuse("there is no Bluetooth adapter"));
            return;
        }
        if (!bluetoothBlocked) {
            enableOnUnblock = false;
            adapter.enabled = !adapter.enabled;
            return;
        }
        Exec.runOr(["rfkill", "unblock", "bluetooth"], stdout => {
            enableOnUnblock = true;
            enableUnblocked();
        }, reason => fail("Cannot unblock Bluetooth: " + reason));
    }

    // BlueZ learns of the unblock after rfkill has exited, and the adapter refuses to power while it is blocked.
    function enableUnblocked(): void {
        if (!adapter)
            enableOnUnblock = false;
        if (!enableOnUnblock || bluetoothBlocked)
            return;
        enableOnUnblock = false;
        adapter.enabled = true;
    }

    function setScanning(on: bool): void {
        if (adapter)
            adapter.discovering = on;
    }

    // The pairings under way, one per device: {device, deviceName, fail}. A pairing that never reports an end (BlueZ refusing it
    // outright) is replaced by the next try on that device, and dropped once its device is gone.
    property var pairings: []

    // Pairs without a PIN, then trusts the device and connects it. Calls fail(reason) when pairing does not end paired.
    function pairDevice(device, fail): void {
        if (device.pairing)
            return;
        pairings = pairings.filter(pairing => pairing.device && pairing.device !== device).concat([
            {
                device: device,
                deviceName: device.name,
                fail: fail
            }
        ]);
        device.pair();
    }

    // BlueZ sets paired before it ends a pairing, so a pairing that ended unpaired failed. Quickshell logs why
    // but exposes no reason, and it registers no agent, so a device that asks for a PIN fails here.
    function settlePairing(pairing: var): void {
        const device = pairing.device;
        if (device.pairing)
            return;
        pairings = pairings.filter(other => other !== pairing);
        if (device.paired) {
            device.trusted = true;
            device.connect();
        } else {
            pairing.fail(pairingFailure(pairing.deviceName));
        }
    }

    function forgetDevice(device): void {
        device.forget();
    }

    function pairingFailure(deviceName: string): string {
        return refuse(deviceName + ": pairing failed (devices that ask for a PIN are not supported)");
    }

    Connections {
        target: root.adapter

        function onStateChanged(): void {
            root.enableUnblocked();
        }
    }

    onAdapterChanged: enableUnblocked()

    Instantiator {
        model: root.pairings

        delegate: Connections {
            required property var modelData

            target: modelData.device

            function onPairingChanged(): void {
                root.settlePairing(modelData);
            }
        }
    }
}

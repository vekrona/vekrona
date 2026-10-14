import Quickshell.Services.UPower
import "Vekrona"

BarPill {
    id: root

    readonly property UPowerDevice battery: UPower.displayDevice
    readonly property int percent: Math.round(100 * battery.percentage)
    readonly property bool charging: battery.state === UPowerDeviceState.Charging
    readonly property bool full: battery.state === UPowerDeviceState.FullyCharged
    readonly property int levels: 6

    visible: battery.isLaptopBattery
    icon: charging ? "battery_charging_full" : full ? "battery_full" : "battery_" + Math.min(levels, Math.floor(levels * percent / 100)) + "_bar"
    filled: charging
    value: percent + " %"
    widestValue: "100 %"
    ariaName: "Battery"
}

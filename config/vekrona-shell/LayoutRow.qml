import QtQuick
import QtQuick.Layouts
import "Vekrona"

// One keyboard layout as a row: a check on the current one, its name, and its code at the right edge.
BarPill {
    required property var layout
    required property bool current

    Layout.fillWidth: true
    keepIconSlot: true
    icon: current ? "check" : ""
    value: layout.name
    trailing: layout.code
    emphasized: current
    ariaName: layout.name + ", " + layout.code + (current ? ", current layout" : "")
}

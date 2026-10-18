import QtQuick
import QtQuick.Layouts
import "Vekrona"

// The rows of a list to wait for, indented under the row that opened them. Nothing shows while the list is still loading;
// a list that could not be read says why.
ColumnLayout {
    id: root

    // Rows {label, trailing, args}; null while loading.
    property var choices: null
    property string emptyText
    // Why the rows could not be read, "" while they can.
    property string failure

    signal picked(var args)

    spacing: 0

    Repeater {
        model: root.choices ?? []

        BarPill {
            required property var modelData

            Layout.fillWidth: true
            Layout.leftMargin: VekronaTheme.space4
            value: modelData.label
            trailing: modelData.trailing
            ariaName: "Wait for " + modelData.label
            onClicked: root.picked(modelData.args)
        }
    }

    Label {
        visible: root.choices !== null && root.choices.length === 0
        Layout.leftMargin: VekronaTheme.space4 + VekronaTheme.space2
        Layout.minimumHeight: VekronaTheme.sizeTarget
        verticalAlignment: Text.AlignVCenter
        style: VekronaTheme.type.caption
        color: VekronaTheme.c.inkMuted
        text: root.emptyText
    }

    Label {
        visible: root.failure !== ""
        Layout.leftMargin: VekronaTheme.space4 + VekronaTheme.space2
        Layout.maximumWidth: VekronaTheme.sizeTarget * 8
        wrapMode: Text.Wrap
        style: VekronaTheme.type.caption
        color: VekronaTheme.c.dangerInk
        text: "Could not read the list: " + root.failure
    }
}

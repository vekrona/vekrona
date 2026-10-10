import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Pipewire
import "Vekrona"
import "."

ColumnLayout {
    spacing: 0

    Repeater {
        model: Audio.sinks

        BarPill {
            required property PwNode modelData

            Layout.fillWidth: true
            icon: "speaker"
            value: modelData.description
            emphasized: modelData === Audio.sink
            ariaName: "Output " + modelData.description
            onClicked: Audio.selectSink(modelData)
        }
    }
}

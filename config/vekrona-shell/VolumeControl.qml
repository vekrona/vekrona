import QtQuick
import QtQuick.Layouts
import "Vekrona"
import "."

RowLayout {
    spacing: VekronaTheme.space2

    BarPill {
        icon: Audio.glyph
        filled: Audio.muted
        ariaName: "Mute"
        onClicked: Audio.toggleMute()
    }

    Slider {
        Layout.fillWidth: true
        value: Audio.volume
        ariaName: "Volume"
        onMoved: fraction => Audio.setVolume(fraction)
    }

    // Fits the widest value, so the slider does not move as the number changes.
    Label {
        Layout.preferredWidth: widest.advanceWidth
        Layout.rightMargin: VekronaTheme.space2
        horizontalAlignment: Text.AlignRight
        style: VekronaTheme.type.label
        text: Audio.percent + " %"

        TextMetrics {
            id: widest
            font.family: VekronaTheme.fontSans
            font.pixelSize: VekronaTheme.type.label.size
            font.weight: VekronaTheme.type.label.weight
            font.letterSpacing: VekronaTheme.type.label.tracking * VekronaTheme.type.label.size
            text: "100 %"
        }
    }
}

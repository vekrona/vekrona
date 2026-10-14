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
    FixedWidthLabel {
        Layout.rightMargin: VekronaTheme.space2
        style: VekronaTheme.type.label
        text: Audio.percent + " %"
        widest: "100 %"
    }
}

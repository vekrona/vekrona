import QtQuick
import QtQuick.Layouts
import "Vekrona"
import "."

BarPill {
    id: root

    required property var bar
    readonly property real wheelStep: 0.05

    icon: Audio.glyph
    value: Audio.percent + " %"
    widestValue: "100 %"
    ariaName: "Sound"
    onClicked: bar.togglePopout(popout)
    onRightClicked: Audio.toggleMute()
    onWheel: delta => Audio.setVolume(Audio.volume + (delta > 0 ? wheelStep : -wheelStep))

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null

        ColumnLayout {
            Layout.preferredWidth: 24 * VekronaTheme.space4
            spacing: 0

            MediaCard {
                id: card
                Layout.fillWidth: true
                visible: Audio.player !== null
                onRaised: root.bar.openPopout = null
            }

            Rule {
                visible: card.visible
            }

            VolumeControl {
                Layout.fillWidth: true
            }

            Rule {}

            OutputList {
                Layout.fillWidth: true
            }
        }
    }
}

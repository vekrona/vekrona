import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Pipewire
import "Vekrona"
import "."

BarPill {
    id: root

    required property var bar
    readonly property real wheelStep: 0.05

    icon: Audio.glyph
    value: Audio.percent + " %"
    ariaName: "Sound"
    onClicked: bar.togglePopout(popout)
    onRightClicked: Audio.toggleMute()
    onWheel: delta => Audio.setVolume(Audio.volume + (delta > 0 ? wheelStep : -wheelStep))

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null

        RowLayout {
            spacing: VekronaTheme.space2

            BarPill {
                icon: "volume_off"
                filled: Audio.muted
                ariaName: "Mute"
                onClicked: Audio.toggleMute()
            }

            Slider {
                value: Audio.volume
                ariaName: "Volume"
                onMoved: fraction => Audio.setVolume(fraction)
            }

            Label {
                style: VekronaTheme.type.label
                text: Audio.percent + " %"
            }
        }

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

        RowLayout {
            visible: Audio.player !== null
            spacing: VekronaTheme.space1

            Label {
                Layout.fillWidth: true
                style: VekronaTheme.type.body
                elide: Text.ElideRight
                text: [Audio.player?.trackTitle, Audio.player?.trackArtist].filter(s => s).join(" - ")
            }

            BarPill {
                icon: "skip_previous"
                ariaName: "Previous track"
                onClicked: Audio.player.previous()
            }

            BarPill {
                icon: Audio.player?.isPlaying ? "pause" : "play_arrow"
                ariaName: "Play or pause"
                onClicked: Audio.player.togglePlaying()
            }

            BarPill {
                icon: "skip_next"
                ariaName: "Next track"
                onClicked: Audio.player.next()
            }
        }
    }
}

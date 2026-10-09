import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "Vekrona"

BarPill {
    id: root

    required property var bar
    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property real volume: sink?.audio?.volume ?? 0
    readonly property bool muted: sink?.audio?.muted ?? true
    readonly property int percent: Math.round(100 * volume)
    readonly property real wheelStep: 0.05
    readonly property var sinks: Pipewire.nodes.values.filter(node => node.type === PwNodeType.AudioSink)
    readonly property MprisPlayer player: Mpris.players.values[0] ?? null

    function setVolume(fraction: real): void {
        sink.audio.volume = Math.max(0, Math.min(1, fraction));
    }

    icon: muted || percent === 0 ? "volume_off" : percent <= 33 ? "volume_down" : "volume_up"
    value: percent + " %"
    ariaName: "Sound"
    onClicked: bar.togglePopout(popout)
    onRightClicked: sink.audio.muted = !muted
    onWheel: delta => setVolume(volume + (delta > 0 ? wheelStep : -wheelStep))

    PwObjectTracker {
        objects: [root.sink]
    }

    Popout {
        id: popout
        anchorItem: root
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null

        RowLayout {
            spacing: VekronaTheme.space2

            BarPill {
                icon: "volume_off"
                filled: root.muted
                ariaName: "Mute"
                onClicked: root.sink.audio.muted = !root.muted
            }

            Slider {
                value: root.volume
                ariaName: "Volume"
                onMoved: fraction => root.setVolume(fraction)
            }

            Label {
                style: VekronaTheme.type.label
                text: root.percent + " %"
            }
        }

        Repeater {
            model: root.sinks

            BarPill {
                required property PwNode modelData

                Layout.fillWidth: true
                icon: "speaker"
                value: modelData.description
                emphasized: modelData === root.sink
                ariaName: "Output " + modelData.description
                onClicked: Pipewire.preferredDefaultAudioSink = modelData
            }
        }

        RowLayout {
            visible: root.player !== null
            spacing: VekronaTheme.space1

            Label {
                Layout.fillWidth: true
                style: VekronaTheme.type.body
                elide: Text.ElideRight
                text: [root.player?.trackTitle, root.player?.trackArtist].filter(s => s).join(" - ")
            }

            BarPill {
                icon: "skip_previous"
                ariaName: "Previous track"
                onClicked: root.player.previous()
            }

            BarPill {
                icon: root.player?.isPlaying ? "pause" : "play_arrow"
                ariaName: "Play or pause"
                onClicked: root.player.togglePlaying()
            }

            BarPill {
                icon: "skip_next"
                ariaName: "Next track"
                onClicked: root.player.next()
            }
        }
    }
}

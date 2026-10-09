import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import "Vekrona"

PanelWindow {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property int hideAfterMs: 1500
    readonly property int trackWidth: 8 * VekronaTheme.sizeTarget
    property string glyph
    property real fraction: 0

    function show(glyphName: string, level: real): void {
        glyph = glyphName;
        fraction = level;
        hide.restart();
    }

    function stepVolume(delta: real): void {
        sink.audio.volume = Math.max(0, Math.min(1, sink.audio.volume + delta));
        show(volumeGlyph(), sink.audio.volume);
    }

    function volumeGlyph(): string {
        const level = sink.audio.volume;
        return sink.audio.muted || level === 0 ? "volume_off" : level <= 0.33 ? "volume_down" : "volume_up";
    }

    function stepBrightness(step: int, sign: string): void {
        const change = changeComponent.createObject(root, {
            step: step + "%" + sign
        });
        change.running = true;
    }

    function player(): MprisPlayer {
        const players = Mpris.players.values;
        return players.find(candidate => candidate.isPlaying) ?? players[0] ?? null;
    }

    visible: hide.running
    color: "transparent"
    anchors.bottom: true
    margins.bottom: 2 * VekronaTheme.sizeTarget
    implicitWidth: panel.width
    implicitHeight: panel.height
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "vekrona-osd"

    PwObjectTracker {
        objects: [root.sink]
    }

    Timer {
        id: hide
        interval: root.hideAfterMs
    }

    Component {
        id: changeComponent

        Process {
            id: change

            required property string step

            command: ["brightnessctl", "--machine-readable", "set", step]
            stdout: StdioCollector {
                onStreamFinished: root.show("brightness_medium", parseInt(text.split(",")[3]) / 100)
            }
            stderr: StdioCollector {
                onStreamFinished: if (text !== "")
                    console.error("brightnessctl: " + text)
            }
            onExited: change.destroy()
        }
    }

    Rectangle {
        id: panel
        width: row.width + 2 * VekronaTheme.space4
        height: row.height + 2 * VekronaTheme.space4
        color: VekronaTheme.c.surface1
        border.width: VekronaTheme.borderHair
        border.color: VekronaTheme.c.line

        Row {
            id: row
            anchors.centerIn: parent
            spacing: VekronaTheme.space2

            Pictogram {
                anchors.verticalCenter: parent.verticalCenter
                px: VekronaTheme.iconM
                name: root.glyph
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: root.trackWidth
                height: VekronaTheme.space2
                color: VekronaTheme.c.surface3

                Rectangle {
                    width: root.fraction * parent.width
                    height: parent.height
                    color: VekronaTheme.c.accent
                }
            }

            Label {
                anchors.verticalCenter: parent.verticalCenter
                style: VekronaTheme.type.label
                text: Math.round(100 * root.fraction) + " %"
            }
        }
    }

    IpcHandler {
        target: "audio"

        function increment(step: int): void {
            root.stepVolume(step / 100);
        }

        function decrement(step: int): void {
            root.stepVolume(-step / 100);
        }

        function mute(): void {
            root.sink.audio.muted = !root.sink.audio.muted;
            root.show(root.volumeGlyph(), root.sink.audio.volume);
        }
    }

    IpcHandler {
        target: "brightness"

        function increment(step: int): void {
            root.stepBrightness(step, "+");
        }

        function decrement(step: int): void {
            root.stepBrightness(step, "-");
        }
    }

    IpcHandler {
        target: "mpris"

        function playPause(): void {
            root.player()?.togglePlaying();
        }

        function pause(): void {
            root.player()?.pause();
        }

        function next(): void {
            root.player()?.next();
        }

        function previous(): void {
            root.player()?.previous();
        }
    }
}

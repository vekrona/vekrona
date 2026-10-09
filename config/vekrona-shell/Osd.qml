import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Vekrona"
import "."

PanelWindow {
    id: root

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
        Audio.setVolume(Audio.volume + delta);
        show(Audio.glyph, Audio.volume);
    }

    function stepBrightness(step: int, sign: string): void {
        const argv = ["brightnessctl", "--machine-readable", "set", step + "%" + sign];
        Exec.run(argv, (code, stdout, stderr) => {
            if (code !== 0)
                Exec.failure(argv, code, stderr);
            else
                show("brightness_medium", parseInt(stdout.split(",")[3]) / 100);
        });
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

    Timer {
        id: hide
        interval: root.hideAfterMs
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
            Audio.toggleMute();
            root.show(Audio.glyph, Audio.volume);
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
            Audio.player?.togglePlaying();
        }

        function pause(): void {
            Audio.player?.pause();
        }

        function next(): void {
            Audio.player?.next();
        }

        function previous(): void {
            Audio.player?.previous();
        }
    }
}

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Vekrona"
import "."

PanelWindow {
    id: root

    readonly property int hideAfterMs: 1500
    readonly property int trackWidth: 8 * VekronaTheme.sizeTarget
    // "volume" shows a pictogram and a level; "layouts" lists the keyboard layouts with the current one marked.
    property string mode: "volume"
    readonly property real layoutsMinWidth: 240 - 2 * VekronaTheme.space4
    property string glyph
    property real fraction: 0

    function show(glyphName: string, level: real): void {
        mode = "volume";
        glyph = glyphName;
        fraction = level;
        restartTimer();
    }

    function showLayouts(): void {
        mode = "layouts";
        restartTimer();
    }

    // Every mode shows through here, so each press holds the panel for hideAfterMs from that press.
    function restartTimer(): void {
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
    // The surface fits every mode and keeps that size: resizing a layer surface as it shows let Sway present a mismatched
    // buffer, which tore the panel. Only the panel inside it changes with the mode; the rest is transparent and takes no input.
    implicitWidth: Math.max(volumeRow.width, layoutsColumn.width) + 2 * VekronaTheme.space4
    implicitHeight: Math.max(volumeRow.height, layoutsColumn.height) + 2 * VekronaTheme.space4
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
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        width: content.width + 2 * VekronaTheme.space4
        height: content.height + 2 * VekronaTheme.space4
        color: VekronaTheme.c.surface1
        border.width: VekronaTheme.borderHair
        border.color: VekronaTheme.c.line

        Item {
            id: content
            anchors.centerIn: parent
            width: root.mode === "layouts" ? layoutsColumn.width : volumeRow.width
            height: root.mode === "layouts" ? layoutsColumn.height : volumeRow.height

            Row {
                id: volumeRow
                visible: root.mode !== "layouts"
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

            ColumnLayout {
                id: layoutsColumn
                visible: root.mode === "layouts"
                width: Math.max(implicitWidth, root.layoutsMinWidth)
                spacing: 0

                Repeater {
                    model: Keyboard.layouts

                    LayoutRow {
                        required property var modelData
                        required property int index

                        layout: modelData
                        current: index === Keyboard.activeIndex
                    }
                }
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

    IpcHandler {
        target: "keyboard"

        function announce(): void {
            if (Keyboard.layouts.length < 2)
                return;
            root.showLayouts();
        }
    }
}

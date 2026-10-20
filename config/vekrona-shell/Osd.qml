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
    property string label

    function show(glyphName: string, level: real): void {
        showLabelled(glyphName, level, Math.round(100 * level) + " %");
    }

    function showLabelled(glyphName: string, level: real, text: string): void {
        mode = "volume";
        glyph = glyphName;
        fraction = level;
        label = text;
        restartTimer();
    }

    function showAudio(): void {
        if (Audio.hasOutput)
            show(Audio.glyph, Audio.volume);
        else
            showLabelled("volume_off", 0, "No output");
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
        showAudio();
    }

    // brightnessctl's machine-readable line is "<device>,<class>,<current>,<percent>%,<max>". Throws on any other.
    function brightnessFraction(line: string): real {
        const match = /^[^,]*,[^,]*,\d+,(\d+)%,\d+\s*$/.exec(line);
        if (match === null)
            throw new Error("unreadable brightnessctl output " + JSON.stringify(line));
        return Number(match[1]) / 100;
    }

    // Changes the brightness by `step` percent, up or down by `sign` ("+" or "-"). A step that is not a positive whole number
    // would be read by brightnessctl as an option or as no change at all.
    function stepBrightness(step: int, sign: string): void {
        if (!(step > 0)) {
            console.error("brightness: the step must be a positive number of percent, not " + step);
            return;
        }
        Exec.runChecked(["brightnessctl", "--machine-readable", "set", step + "%" + sign], stdout => {
            let level;
            try {
                level = brightnessFraction(stdout);
            } catch (e) {
                console.error("brightness: " + e);
                return;
            }
            show("brightness_medium", level);
        });
    }

    visible: hide.running
    color: VekronaTheme.c.surface1
    anchors.bottom: true
    margins.bottom: 2 * VekronaTheme.sizeTarget
    // The surface fits every mode and keeps that size: resizing a layer surface as it shows let Sway present a mismatched
    // buffer, which tore the panel. Content changes with the mode; the whole surface is opaque and takes no input.
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
        anchors.fill: parent
        color: "transparent"
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
                    text: root.label
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
            root.showAudio();
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

    // Shown once Sway reports the new layout, so the panel maps with its final content instead of redrawing as it appears.
    Connections {
        target: Keyboard

        function onSwitched(): void {
            root.showLayouts();
        }
    }
}

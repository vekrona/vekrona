import QtQuick
import QtQuick.Layouts
import "Vekrona"
import "."

BarPill {
    id: root

    required property var bar
    readonly property real wheelStep: 0.05

    // An icon, as for every bar widget, and the words instead of it while there is no default sink: the interface behind a KVM is away.
    icon: Audio.hasOutput ? Audio.glyph : ""
    value: Audio.hasOutput ? "" : Audio.levelText
    ariaName: "Sound"
    onClicked: bar.togglePopout(popout)
    onRightClicked: Audio.toggleMute()
    onWheel: delta => {
        const steps = notches.steps(delta);
        if (steps !== 0)
            Audio.setVolume(Audio.volume + steps * wheelStep);
    }

    WheelSteps {
        id: notches
    }

    // The volume is the speaker's fill: the filled glyph, shown from the bottom of the glyph's ink up to the volume. A muted speaker has none.
    Item {
        id: fill
        readonly property real inkTop: fillGlyph.baselineOffset + inkBounds.tightBoundingRect.y
        readonly property real inkHeight: inkBounds.tightBoundingRect.height

        visible: !Audio.muted
        width: parent.width
        y: inkTop + inkHeight * (1 - Math.max(0, Math.min(1, Audio.volume)))
        height: parent.height - y
        clip: true

        TextMetrics {
            id: inkBounds
            font: fillGlyph.font
            text: fillGlyph.text
        }

        Pictogram {
            id: fillGlyph
            y: -fill.y
            name: Audio.glyph
            filled: true
        }
    }

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

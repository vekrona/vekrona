import QtQuick

// Tells a dot when to dim so that it pulses: it pulses once when the count it shows rises, three times dim and solid, and
// then it stays solid. A fall or a zero never pulses. Three cycles of two timer ticks last 1.8 s and then nothing runs:
// the timer wakes six times per pulse, an animation would redraw every frame.
QtObject {
    id: root

    property int count: 0
    // False while the count has still to be read: the first count that arrives is the one the dot starts on, not a rise.
    // Set it after the count, so that the count it settles on is not taken for a rise.
    property bool known: true
    // Half-cycles of a pulse: dim, solid, dim, solid, dim, solid.
    readonly property int phases: 6
    readonly property int phaseMs: 300
    property int phasesLeft: 0
    property int shownCount: 0
    readonly property bool pulsing: phasesLeft > 0
    readonly property bool dim: pulsing && phasesLeft % 2 === 0

    onCountChanged: {
        if (!known)
            return;
        if (count > shownCount) {
            phasesLeft = phases;
            blink.restart();
        } else {
            phasesLeft = 0;
        }
        shownCount = count;
    }

    onKnownChanged: {
        if (known)
            shownCount = count;
    }

    property Timer blink: Timer {
        interval: root.phaseMs
        repeat: true
        running: root.pulsing
        onTriggered: root.phasesLeft--
    }
}

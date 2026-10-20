import QtQuick

// Turns the wheel events of a mouse or a trackpad into whole steps. A mouse wheel sends one notch (120) per click, a trackpad
// many small deltas, so a widget that stepped once per event would jump by a different amount on each.
QtObject {
    readonly property int notch: 120
    property real pending: 0

    // Adds the angleDelta.y of one wheel event and returns the whole notches that makes, positive away from the user.
    function steps(delta: real): int {
        pending += delta;
        const whole = Math.trunc(pending / notch);
        pending -= whole * notch;
        return whole;
    }
}

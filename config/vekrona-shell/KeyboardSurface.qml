pragma Singleton
import QtQuick

// Who holds the keyboard: the launcher and the notification centre take it exclusively, and a popout takes it when it is
// clicked, so two of them open together would fight over it. Every surface that comes up claims it here, and every other
// one that is up closes on the claim.
QtObject {
    // `owner` is the surface that came up.
    signal claimed(var owner)

    function claim(owner: var): void {
        claimed(owner);
    }
}

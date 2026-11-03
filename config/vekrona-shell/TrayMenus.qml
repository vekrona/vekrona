pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The one place that asks every tray menu on every screen to close. A tray menu is a popup above the bar that grabs nothing
// but its own input, so a tool that puts its own overlay on screen (`vekrona-screenshot`'s selection) asks for it here first.
Singleton {
    id: root

    // Each Tray listens and closes the menus it has open.
    signal closeRequested

    IpcHandler {
        target: "tray"

        function closeMenus(): void {
            root.closeRequested();
        }
    }
}

//@ pragma UseQApplication
import QtQuick
import Quickshell
import "launcher"

ShellRoot {
    // QML singletons are created on first reference, and the bar that references Notifications exists only once a screen does
    Component.onCompleted: Notifications.setCenterOpen(false)

    Launcher {
        id: launcher
    }

    Osd {}

    Polkit {}

    Variants {
        model: Quickshell.screens

        Bar {
            launcher: launcher
        }
    }
}

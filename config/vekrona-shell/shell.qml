//@ pragma UseQApplication
import QtQuick
import Quickshell
import "launcher"

ShellRoot {
    // A reload that starts while git is still writing the checkout fails on half-written files and is never repeated, so a failure is retried once
    property bool retrying: false

    // One journal line, deepest cause first: a record's title keeps only the start of the line
    function causes(errorString: string): string {
        return errorString.split("\n").map(line => line.trim()).reverse().join(" / ");
    }

    function settleReloadFailure(errorString: string): void {
        if (retrying) {
            retrying = false;
            console.error("shell kept its previous version, reload failed: " + causes(errorString));
        } else {
            retrying = true;
            Quickshell.reload(false);
        }
    }

    Connections {
        target: Quickshell

        // Quickshell reports one failure twice in a row, and callLater folds the two into one call
        function onReloadFailed(errorString: string): void {
            Qt.callLater(settleReloadFailure, errorString);
        }
    }

    // QML singletons are created on first reference, and the bar that references Notifications exists only once a screen does
    Component.onCompleted: Notifications.setCenterOpen(false)

    Launcher {
        id: appLauncher
    }

    Osd {}

    Polkit {}

    Variants {
        model: Quickshell.screens

        Bar {
            launcher: appLauncher
        }
    }
}

import QtQuick
import "modules"

// Every launcher module, in the order their sections tie in the root search.
Item {
    id: root

    required property var launcher
    readonly property var all: [apps, calculator, settings, power, web, agent, clipboard]

    Apps {
        id: apps
        launcher: root.launcher
    }

    Calculator {
        id: calculator
        launcher: root.launcher
    }

    Settings {
        id: settings
        launcher: root.launcher
    }

    Power {
        id: power
        launcher: root.launcher
    }

    Web {
        id: web
        launcher: root.launcher
    }

    Agent {
        id: agent
        launcher: root.launcher
    }

    Clipboard {
        id: clipboard
        launcher: root.launcher
    }
}

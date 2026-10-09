import Quickshell

ShellRoot {
    Launcher {
        id: launcher
    }

    Clipboard {}

    PowerMenu {}

    Osd {}

    Variants {
        model: Quickshell.screens

        Bar {
            launcher: launcher
        }
    }
}

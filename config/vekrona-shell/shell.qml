//@ pragma UseQApplication
import Quickshell

ShellRoot {
    Launcher {
        id: launcher
    }

    Clipboard {}

    PowerMenu {}

    Osd {}

    Polkit {}

    Variants {
        model: Quickshell.screens

        Bar {
            launcher: launcher
        }
    }
}

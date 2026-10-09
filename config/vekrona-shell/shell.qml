//@ pragma UseQApplication
import Quickshell
import "launcher"

ShellRoot {
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

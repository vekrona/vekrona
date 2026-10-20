pragma Singleton
import QtQuick
import Quickshell

// Where vekrona keeps the state it writes at run time: $XDG_STATE_HOME/vekrona. Every reader of that directory asks here.
Singleton {
    readonly property string path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/vekrona"
}

import QtQuick
import Quickshell.Wayland
import "Vekrona"

Label {
    style: VekronaTheme.type.body
    color: VekronaTheme.c.inkMuted
    elide: Text.ElideRight
    text: ToplevelManager.activeToplevel?.title ?? ""
}

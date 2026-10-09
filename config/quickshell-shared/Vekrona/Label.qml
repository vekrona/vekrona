import QtQuick
import "."

Text {
    required property var style

    color: VekronaTheme.c.ink
    font.family: VekronaTheme.fontSans
    font.pixelSize: style.size
    font.weight: style.weight
    font.letterSpacing: style.tracking * style.size
}

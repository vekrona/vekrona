import QtQuick
import "."

Text {
    property string name
    property int px: VekronaTheme.iconS
    property bool filled: false

    width: px
    height: px
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    // A glyph name is looked up as a ligature; markup in it would be drawn, not shown.
    textFormat: Text.PlainText
    color: VekronaTheme.c.ink
    text: VekronaTheme.icon(name)
    font.family: VekronaTheme.fontIcon
    font.pixelSize: px
    font.variableAxes: ({ "FILL": filled ? 1 : 0, "opsz": px, "wght": 300 })
}

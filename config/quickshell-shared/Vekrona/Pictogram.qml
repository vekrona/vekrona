import QtQuick
import "."

Text {
    property string name
    property int px: VekronaTheme.iconS
    property bool filled: false
    // Glyphs that Material draws smaller in their em square than most (the sync arrows fill 11 of 18 px where a check mark or a
    // bell fills 13 to 16), drawn larger so that their ink is as tall as their neighbours'. The box keeps its size.
    readonly property var inkScales: ({ sync: 1.3, sync_problem: 1.3, sync_disabled: 1.3 })

    width: px
    height: px
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    // A glyph name is looked up as a ligature; markup in it would be drawn, not shown.
    textFormat: Text.PlainText
    color: VekronaTheme.c.ink
    text: VekronaTheme.icon(name)
    font.family: VekronaTheme.fontIcon
    font.pixelSize: Math.round(px * (inkScales[name] ?? 1))
    font.variableAxes: ({ "FILL": filled ? 1 : 0, "opsz": px, "wght": 300 })
}

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
    color: VekronaTheme.c.ink
    text: VekronaTheme.icon(name)
    font.family: VekronaTheme.fontIcon
    font.pixelSize: px
    font.variableAxes: ({ "FILL": filled ? 1 : 0, "opsz": px })
}

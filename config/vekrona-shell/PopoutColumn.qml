import QtQuick.Layouts
import "Vekrona"

// The body of a wide popout (sound, sync, VPN): one column of a fixed width, no gaps between its rows.
ColumnLayout {
    // The width, in steps of the largest spacing of the theme, so that it follows the theme's scale.
    readonly property int widthInSpaces: 24

    Layout.preferredWidth: widthInSpaces * VekronaTheme.space4
    spacing: 0
}

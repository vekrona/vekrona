pragma Singleton
import QtQuick
import "../Vekrona"

// The launcher's sizes, all multiples of the Vekrona size tokens.
QtObject {
    readonly property real panelWidth: 20 * VekronaTheme.sizeTarget
    readonly property real searchHeight: 3 * VekronaTheme.sizeTarget / 2
    readonly property real rowHeight: 5 * VekronaTheme.sizeTarget / 4
    readonly property real cardHeight: 2 * rowHeight
    readonly property real headerHeight: VekronaTheme.space6 + VekronaTheme.space1
    readonly property real footerHeight: VekronaTheme.sizeTarget
    readonly property real actionsWidth: 35 * VekronaTheme.sizeTarget / 4
    readonly property real actionHeight: VekronaTheme.sizeTarget
    readonly property int maxRows: 8
    readonly property int minRows: 3
    readonly property int maxActions: 6

    // The height of one list entry: {type: "row" | "header" | "empty", result?}.
    function heightOf(entry): real {
        if (entry.type === "header")
            return headerHeight;
        return entry.type === "row" && entry.result.card === "calc" ? cardHeight : rowHeight;
    }
}

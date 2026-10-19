import QtQuick
import "."

// A Label whose text the mouse can select and Ctrl+C copies. It cannot elide, so it shows its full text.
TextEdit {
    id: root

    required property var style

    // A click that selected nothing: a drag selects, and a double or triple click selects a word or a line, so none of
    // them is one. A tap is told apart from the first tap of a double click only once the double-click interval passed.
    signal clicked

    readOnly: true
    selectByMouse: true
    textFormat: TextEdit.PlainText
    color: VekronaTheme.c.ink
    selectionColor: VekronaTheme.c.accent
    selectedTextColor: VekronaTheme.c.onAccent
    font.family: VekronaTheme.fontSans
    font.pixelSize: style.size
    font.weight: style.weight
    font.letterSpacing: style.tracking * style.size

    Timer {
        id: lone

        interval: Qt.styleHints.mouseDoubleClickInterval
        onTriggered: root.clicked()
    }

    TapHandler {
        onTapped: {
            if (tapCount === 1)
                lone.restart();
            else
                lone.stop();
        }
    }
}

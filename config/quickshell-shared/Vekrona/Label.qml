import QtQuick
import "."

Text {
    required property var style

    // What a label shows is text, not markup: titles of windows, errors and notifications are not trusted.
    textFormat: Text.PlainText
    color: VekronaTheme.c.ink
    font.family: VekronaTheme.fontSans
    font.pixelSize: style.size
    font.weight: style.weight
    font.letterSpacing: style.tracking * style.size
}

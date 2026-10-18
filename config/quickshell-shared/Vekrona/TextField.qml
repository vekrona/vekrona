import QtQuick
import "."

// Bordered single-line input. The input is clipped to the frame, so long text
// (and wide password bullets) never draw over the border; the focus ring is a
// sibling of the clipped input and stays outside it.
FocusScope {
    id: field

    property alias text: input.text
    property alias echoMode: input.echoMode
    property string placeholder
    property string accessibleName
    property var colors: VekronaTheme.c
    property color fill: "transparent"
    property color borderColor: enabled ? colors.line : colors.inkDisabled
    property real padding: VekronaTheme.space2

    signal accepted
    // The user changed the text; a change made by setting `text` does not emit it.
    signal textEdited
    signal keyPressed(var event)

    implicitHeight: VekronaTheme.sizeTarget

    Rectangle {
        anchors.fill: parent
        color: field.fill
        border.width: VekronaTheme.borderControl
        border.color: field.borderColor
    }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.margins: field.padding
        clip: true
        focus: true
        verticalAlignment: TextInput.AlignVCenter
        color: field.colors.ink
        selectionColor: field.colors.accent
        selectedTextColor: field.colors.onAccent
        font.family: VekronaTheme.fontSans
        font.pixelSize: VekronaTheme.type.body.size
        font.weight: VekronaTheme.type.body.weight
        font.letterSpacing: VekronaTheme.type.body.tracking * VekronaTheme.type.body.size
        Accessible.name: field.accessibleName
        Keys.onPressed: event => field.keyPressed(event)
        onAccepted: field.accepted()
        onTextEdited: field.textEdited()
    }

    Label {
        visible: input.text === ""
        anchors.fill: input
        verticalAlignment: Text.AlignVCenter
        style: VekronaTheme.type.body
        color: field.colors.inkMuted
        text: field.placeholder
    }

    FocusRing {
        shown: field.activeFocus
        outer: field.colors.focus
        inner: field.colors.focusInner
    }
}

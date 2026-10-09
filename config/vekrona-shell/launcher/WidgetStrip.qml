import QtQuick
import "../Vekrona"

// The modules' always-visible widgets, in one row under the search field. Each widget is one keyboard
// stop: Tab and Shift+Tab move from widget to widget and out to the search field, which Escape
// also returns to. What Left, Right, Enter and Space do is up to the widget.
FocusScope {
    id: root

    required property var launcher
    required property var modules
    readonly property var carriers: modules.filter(module => module.widget !== null)
    readonly property bool populated: carriers.length > 0

    signal leave

    function widgetAt(position: int): Item {
        return repeater.itemAt(position).content;
    }

    function focusedPosition(): int {
        for (let position = 0; position < repeater.count; position++) {
            if (widgetAt(position).activeFocus)
                return position;
        }
        return -1;
    }

    function enter(fromEnd: bool): void {
        widgetAt(fromEnd ? repeater.count - 1 : 0).forceActiveFocus();
    }

    function step(delta: int): void {
        const next = focusedPosition() + delta;
        if (next < 0 || next >= repeater.count)
            leave();
        else
            widgetAt(next).forceActiveFocus();
    }

    visible: populated
    implicitHeight: populated ? row.implicitHeight + 2 * VekronaTheme.space2 + VekronaTheme.borderHair : 0
    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Tab:
            step(1);
            break;
        case Qt.Key_Backtab:
            step(-1);
            break;
        case Qt.Key_Escape:
            leave();
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    Row {
        id: row
        x: VekronaTheme.space4
        y: VekronaTheme.space2
        spacing: VekronaTheme.space4

        Repeater {
            id: repeater
            model: root.carriers

            delegate: Item {
                id: slot

                required property var modelData
                property Item content: null

                implicitWidth: content ? content.implicitWidth : 0
                implicitHeight: content ? content.implicitHeight : 0
                width: implicitWidth
                height: implicitHeight

                Component.onCompleted: {
                    content = modelData.widget.createObject(slot, {
                        launcher: root.launcher,
                        module: modelData
                    });
                    if (content === null)
                        console.error("launcher: the widget of " + modelData.moduleId + " failed to load");
                }
            }
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: VekronaTheme.borderHair
        color: VekronaTheme.c.line
    }
}

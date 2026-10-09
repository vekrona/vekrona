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

    // The widgets that loaded, in order: the keyboard stops. One that failed to load is no stop.
    function stops(): var {
        const loaded = [];
        for (let position = 0; position < repeater.count; position++) {
            const content = repeater.itemAt(position).content;
            if (content !== null)
                loaded.push(content);
        }
        return loaded;
    }

    function enter(fromEnd: bool): void {
        const loaded = stops();
        if (loaded.length === 0)
            leave();
        else
            loaded[fromEnd ? loaded.length - 1 : 0].forceActiveFocus();
    }

    function step(delta: int): void {
        const loaded = stops();
        const next = loaded.findIndex(widget => widget.activeFocus) + delta;
        if (next < 0 || next >= loaded.length)
            leave();
        else
            loaded[next].forceActiveFocus();
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

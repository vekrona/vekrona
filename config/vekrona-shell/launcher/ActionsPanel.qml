import QtQuick
import QtQuick.Layouts
import "../Vekrona"
import "."

// The Ctrl+K panel: every action of the selected row, filtered by what is typed in its own field.
FocusScope {
    id: root

    property var actions: []
    property int current: 0
    readonly property var filtered: actions.filter(action => action.label.toLowerCase().includes(filter.text.trim().toLowerCase()))

    signal chosen(var action)
    signal dismissed

    // Clears the filter and takes the keyboard focus.
    function start(): void {
        filter.text = "";
        current = 0;
        filter.forceActiveFocus();
    }

    function move(delta: int): void {
        if (filtered.length > 0)
            current = Math.max(0, Math.min(filtered.length - 1, current + delta));
    }

    function handleKey(event): void {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        switch (event.key) {
        case Qt.Key_Escape:
            dismissed();
            break;
        case Qt.Key_K:
            if (!ctrl)
                return;
            dismissed();
            break;
        case Qt.Key_Up:
            move(-1);
            break;
        case Qt.Key_Down:
            move(1);
            break;
        case Qt.Key_N:
            if (!ctrl)
                return;
            move(1);
            break;
        case Qt.Key_P:
            if (!ctrl)
                return;
            move(-1);
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (filtered.length > 0)
                chosen(filtered[current]);
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    implicitWidth: LauncherMetrics.actionsWidth
    implicitHeight: LauncherMetrics.rowHeight + Math.max(1, Math.min(filtered.length, LauncherMetrics.maxActions)) * LauncherMetrics.actionHeight + 3 * VekronaTheme.borderHair
    onFilteredChanged: current = 0

    Rectangle {
        anchors.fill: parent
        color: VekronaTheme.c.surface2
        border.width: VekronaTheme.borderHair
        border.color: VekronaTheme.c.lineStrong
    }

    MouseArea {
        anchors.fill: parent
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: VekronaTheme.borderHair
        spacing: 0

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: LauncherMetrics.rowHeight

            TextInput {
                id: filter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: VekronaTheme.space4
                anchors.rightMargin: VekronaTheme.space4
                anchors.verticalCenter: parent.verticalCenter
                color: VekronaTheme.c.ink
                font.family: VekronaTheme.fontSans
                font.pixelSize: VekronaTheme.type.body.size
                Accessible.name: "Filter actions"
                Keys.onPressed: event => root.handleKey(event)
            }

            Label {
                visible: filter.text === ""
                anchors.fill: filter
                verticalAlignment: Text.AlignVCenter
                style: VekronaTheme.type.body
                color: VekronaTheme.c.inkMuted
                text: "Filter actions"
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: VekronaTheme.borderHair
                color: VekronaTheme.c.line
            }
        }

        Label {
            visible: root.filtered.length === 0
            Layout.leftMargin: VekronaTheme.space4
            Layout.preferredHeight: LauncherMetrics.actionHeight
            verticalAlignment: Text.AlignVCenter
            style: VekronaTheme.type.body
            color: VekronaTheme.c.inkMuted
            text: "No actions"
        }

        ListView {
            id: list
            visible: root.filtered.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(root.filtered.length, LauncherMetrics.maxActions) * LauncherMetrics.actionHeight
            clip: true
            interactive: false
            model: root.filtered
            currentIndex: root.current

            delegate: Item {
                id: item

                required property var modelData
                required property int index

                width: ListView.view.width
                height: LauncherMetrics.actionHeight

                Selection {
                    shown: item.index === root.current
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: VekronaTheme.space4
                    anchors.rightMargin: VekronaTheme.space4
                    spacing: VekronaTheme.space2

                    Label {
                        Layout.fillWidth: true
                        style: VekronaTheme.type.body
                        color: item.modelData.destructive === true ? VekronaTheme.c.dangerInk : VekronaTheme.c.ink
                        elide: Text.ElideRight
                        text: item.modelData.label
                    }

                    Label {
                        style: VekronaTheme.type.caption
                        color: VekronaTheme.c.inkMuted
                        text: item.modelData.key ?? ""
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: root.current = item.index
                    onClicked: root.chosen(item.modelData)
                }
            }

            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        }
    }
}

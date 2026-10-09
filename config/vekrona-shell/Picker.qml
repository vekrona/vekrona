import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Vekrona"

PanelWindow {
    id: root

    property bool open: false
    property bool searchable: true
    property string placeholder
    property string namespace
    property string ipcTarget
    property int rows: 8
    property var items: []
    property int current: 0
    readonly property string query: search.text
    readonly property int panelWidth: 12 * VekronaTheme.sizeTarget

    signal chosen(var item)

    function handleKey(event): void {
        switch (event.key) {
        case Qt.Key_Escape:
            open = false;
            break;
        case Qt.Key_Up:
            current = Math.max(0, current - 1);
            break;
        case Qt.Key_Down:
            current = Math.min(items.length - 1, current + 1);
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (items.length > 0)
                choose(items[current]);
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    function toggle(): void {
        open = !open;
    }

    function choose(item): void {
        open = false;
        chosen(item);
    }

    visible: open
    color: "transparent"
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: root.namespace
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    onItemsChanged: current = 0
    onOpenChanged: {
        if (open) {
            search.text = "";
            current = 0;
            scope.forceActiveFocus();
        }
    }

    IpcHandler {
        target: root.ipcTarget

        function toggle(): void {
            root.toggle();
        }
    }

    Rectangle {
        anchors.fill: parent
        color: VekronaTheme.c.scrim
        opacity: VekronaTheme.scrimOpacity
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.open = false
    }

    Rectangle {
        anchors.centerIn: parent
        width: root.panelWidth
        height: column.implicitHeight + 2 * VekronaTheme.space4
        color: VekronaTheme.c.surface1
        border.width: VekronaTheme.borderHair
        border.color: VekronaTheme.c.line

        MouseArea {
            anchors.fill: parent
        }

        FocusScope {
            id: scope
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => root.handleKey(event)

            ColumnLayout {
                id: column
                anchors.fill: parent
                anchors.margins: VekronaTheme.space4
                spacing: VekronaTheme.space2

                Rectangle {
                    visible: root.searchable
                    Layout.fillWidth: true
                    implicitHeight: VekronaTheme.sizeTarget
                    color: "transparent"
                    border.width: VekronaTheme.borderControl
                    border.color: VekronaTheme.c.line

                    TextInput {
                        id: search
                        anchors.fill: parent
                        anchors.margins: VekronaTheme.space2
                        verticalAlignment: TextInput.AlignVCenter
                        focus: root.searchable
                        color: VekronaTheme.c.ink
                        font.family: VekronaTheme.fontSans
                        font.pixelSize: VekronaTheme.type.body.size
                        Accessible.name: root.placeholder
                        Keys.onPressed: event => root.handleKey(event)
                    }

                    Label {
                        visible: search.text === ""
                        anchors.fill: search
                        verticalAlignment: Text.AlignVCenter
                        style: VekronaTheme.type.body
                        color: VekronaTheme.c.inkMuted
                        text: root.placeholder
                    }

                    FocusRing {
                        shown: search.activeFocus
                    }
                }

                ListView {
                    Layout.fillWidth: true
                    implicitHeight: root.rows * VekronaTheme.sizeTarget
                    clip: true
                    interactive: false
                    model: root.items
                    currentIndex: root.current

                    delegate: Item {
                        id: row

                        required property var modelData
                        required property int index

                        width: ListView.view.width
                        height: VekronaTheme.sizeTarget

                        Selection {
                            shown: row.ListView.isCurrentItem
                        }

                        Row {
                            x: VekronaTheme.space2
                            width: parent.width - 2 * VekronaTheme.space2
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: VekronaTheme.space2

                            Pictogram {
                                visible: (row.modelData.glyph ?? "") !== ""
                                px: VekronaTheme.iconM
                                name: row.modelData.glyph ?? ""
                            }

                            Image {
                                visible: (row.modelData.iconPath ?? "") !== ""
                                width: VekronaTheme.iconM
                                height: VekronaTheme.iconM
                                sourceSize.width: VekronaTheme.iconM
                                sourceSize.height: VekronaTheme.iconM
                                source: row.modelData.iconPath ?? ""
                            }

                            Label {
                                width: parent.width - VekronaTheme.iconM - VekronaTheme.space2
                                anchors.verticalCenter: parent.verticalCenter
                                style: VekronaTheme.type.body
                                elide: Text.ElideRight
                                text: row.modelData.label
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: root.current = row.index
                            onClicked: root.choose(row.modelData)
                        }
                    }
                }

                Label {
                    visible: root.items.length === 0
                    style: VekronaTheme.type.body
                    color: VekronaTheme.c.inkMuted
                    text: "No matches"
                }
            }
        }
    }
}

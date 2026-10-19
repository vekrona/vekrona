import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "Vekrona"

// The shared Popout with content whose height an IPC call changes, and a record of where that content sat inside the popout
// window at every change of its geometry or its ancestors'. A popout window follows its content's size only after a round trip
// to the compositor, and the content must not move in the meantime: the record holds one position when it never did.
ShellRoot {
    id: root

    readonly property int shortHeight: 100
    readonly property int tallHeight: 600
    property bool tall: false
    property bool open: true
    // The content's distinct positions in the popout window, in the order it held them.
    property var positions: []

    function sample(): void {
        const at = content.mapToItem(null, 0, 0);
        const position = at.x + "," + at.y;
        if (positions[positions.length - 1] !== position)
            positions = positions.concat([position]);
    }

    PanelWindow {
        id: host

        anchors.top: true
        anchors.left: true
        implicitWidth: 200
        implicitHeight: VekronaTheme.sizeBar
        exclusionMode: ExclusionMode.Ignore

        Item {
            id: anchor
            anchors.fill: parent
        }
    }

    Popout {
        id: popout

        anchorItem: anchor
        open: root.open
        onWidthChanged: root.sample()
        onHeightChanged: root.sample()

        ColumnLayout {
            id: content

            spacing: 0

            Component.onCompleted: {
                for (let item = content; item; item = item.parent) {
                    item.xChanged.connect(root.sample);
                    item.yChanged.connect(root.sample);
                    item.widthChanged.connect(root.sample);
                    item.heightChanged.connect(root.sample);
                }
            }

            Rectangle {
                color: "transparent"
                implicitWidth: 200
                implicitHeight: root.tall ? root.tallHeight : root.shortHeight
            }

            Item {
                implicitWidth: 200
                implicitHeight: root.shortHeight

                TextInput {
                    id: field
                    anchors.fill: parent
                }
            }
        }
    }

    IpcHandler {
        target: "popout"

        // The content's height is shortHeight plus tallHeight when `tall`, else shortHeight twice.
        function setTall(tall: bool): void {
            root.tall = tall;
        }

        function setOpen(open: bool): void {
            root.open = open;
        }

        function focusField(): void {
            field.forceActiveFocus();
        }

        // Whether the text field holds the focus of its popout.
        function fieldFocused(): bool {
            return field.focus;
        }

        function forget(): void {
            root.positions = [];
            root.sample();
        }

        // "<window height> <position> <position> ...": the window's height now and the positions since forget().
        function report(): string {
            return popout.height + " " + root.positions.join(" ");
        }
    }
}

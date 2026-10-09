import QtQuick
import QtQuick.Layouts
import "../Vekrona"
import "."

// The line under the list: the module of the selected row on the left, what Enter and Ctrl+K do on the right.
Item {
    id: root

    property string glyph
    property string title
    property string toastText
    // The label of the primary action of the selected row, or "" when it has none.
    property string primaryLabel
    // The label of the armed action, or "" when nothing is armed.
    property string armedLabel
    property bool hasActions: false

    signal primaryClicked
    signal actionsClicked

    // A label with the key that triggers it, e.g. "Open" and "↵".
    component Hint: Item {
        id: hint

        property string label
        property string key

        signal clicked

        implicitWidth: row.implicitWidth
        implicitHeight: LauncherMetrics.footerHeight

        Row {
            id: row
            anchors.verticalCenter: parent.verticalCenter
            spacing: VekronaTheme.space1

            Label {
                style: VekronaTheme.type.label
                text: hint.label
            }

            Label {
                style: VekronaTheme.type.caption
                color: VekronaTheme.c.inkMuted
                text: hint.key
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: hint.clicked()
        }
    }

    implicitHeight: LauncherMetrics.footerHeight

    Rectangle {
        width: parent.width
        height: VekronaTheme.borderHair
        color: VekronaTheme.c.line
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: VekronaTheme.space4
        anchors.rightMargin: VekronaTheme.space4
        spacing: VekronaTheme.space4

        RowLayout {
            Layout.fillWidth: true
            spacing: VekronaTheme.space2

            Pictogram {
                visible: root.toastText === "" && root.glyph !== ""
                name: root.glyph
                color: VekronaTheme.c.inkMuted
            }

            Label {
                Layout.fillWidth: true
                elide: Text.ElideRight
                style: root.toastText === "" ? VekronaTheme.type.caption : VekronaTheme.type.label
                color: root.toastText === "" ? VekronaTheme.c.inkMuted : VekronaTheme.c.ink
                text: root.toastText === "" ? root.title : root.toastText
            }
        }

        Hint {
            visible: root.armedLabel !== ""
            label: root.armedLabel
            key: "↵"
            onClicked: root.primaryClicked()
        }

        Hint {
            visible: root.armedLabel !== ""
            label: "Cancel"
            key: "Esc"
        }

        Hint {
            visible: root.armedLabel === "" && root.primaryLabel !== ""
            label: root.primaryLabel
            key: "↵"
            onClicked: root.primaryClicked()
        }

        Rectangle {
            visible: root.armedLabel === "" && root.hasActions
            Layout.preferredWidth: VekronaTheme.borderHair
            Layout.preferredHeight: 0.6 * LauncherMetrics.footerHeight
            color: VekronaTheme.c.line
        }

        Hint {
            visible: root.armedLabel === "" && root.hasActions
            label: "Actions"
            key: "Ctrl K"
            onClicked: root.actionsClicked()
        }
    }
}

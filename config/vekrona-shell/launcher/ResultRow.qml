import QtQuick
import QtQuick.Layouts
import "../Vekrona"
import "."

// One list entry: a section header, the "No matches" line, a result row or the calculator card.
Item {
    id: root

    // {type: "header" | "empty", title} or {type: "row", result, module, synthetic}
    required property var entry
    required property bool current
    // The confirm text of the armed action, or "" when this row is not armed.
    required property string armedText

    readonly property bool armed: armedText !== ""
    readonly property var result: entry.result ?? null
    readonly property bool card: result !== null && result.card === "calc"
    readonly property string iconPath: result?.iconPath ?? ""
    readonly property string glyph: result?.glyph ?? ""

    signal moved
    signal clicked

    function oneLine(text: string): string {
        return text.replace(/\s*\n\s*/g, " ");
    }

    height: LauncherMetrics.heightOf(entry)
    Accessible.role: entry.type === "row" ? Accessible.ListItem : Accessible.StaticText
    Accessible.name: entry.type === "row" ? result.title : entry.title

    Label {
        visible: root.entry.type === "header"
        x: VekronaTheme.space4
        width: parent.width - 2 * VekronaTheme.space4
        anchors.verticalCenter: parent.verticalCenter
        style: VekronaTheme.type.label
        color: VekronaTheme.c.inkMuted
        elide: Text.ElideRight
        text: root.entry.title
    }

    Label {
        visible: root.entry.type === "empty"
        x: VekronaTheme.space4
        anchors.verticalCenter: parent.verticalCenter
        style: VekronaTheme.type.body
        color: VekronaTheme.c.inkMuted
        text: root.entry.title
    }

    Item {
        visible: root.entry.type === "row"
        anchors.fill: parent

        Selection {
            shown: root.current
        }

        RowLayout {
            visible: !root.card
            anchors.fill: parent
            anchors.leftMargin: VekronaTheme.space4
            anchors.rightMargin: VekronaTheme.space4
            spacing: VekronaTheme.space2

            Item {
                Layout.preferredWidth: VekronaTheme.iconM
                Layout.preferredHeight: VekronaTheme.iconM

                Image {
                    visible: root.iconPath !== ""
                    anchors.fill: parent
                    sourceSize.width: VekronaTheme.iconM
                    sourceSize.height: VekronaTheme.iconM
                    asynchronous: true
                    source: root.iconPath
                }

                Pictogram {
                    visible: root.iconPath === "" && root.glyph !== ""
                    px: VekronaTheme.iconM
                    name: root.glyph
                    color: root.armed ? VekronaTheme.c.dangerInk : VekronaTheme.c.ink
                }
            }

            Label {
                Layout.maximumWidth: LauncherMetrics.rowTitleMaxWidth
                style: VekronaTheme.type.body
                elide: Text.ElideRight
                text: root.result === null ? "" : root.armed ? root.armedText : root.oneLine(root.result.title)
            }

            Label {
                Layout.fillWidth: true
                style: VekronaTheme.type.caption
                color: VekronaTheme.c.inkMuted
                elide: Text.ElideRight
                text: root.result === null || root.armed ? "" : root.oneLine(root.result.subtitle ?? "")
            }

            Pictogram {
                visible: root.result !== null && root.result.checked === true
                name: "check"
            }

            Label {
                style: VekronaTheme.type.caption
                color: VekronaTheme.c.inkMuted
                text: root.result?.kind ?? ""
            }
        }

        RowLayout {
            visible: root.card
            anchors.fill: parent
            anchors.leftMargin: VekronaTheme.space4
            anchors.rightMargin: VekronaTheme.space4
            spacing: VekronaTheme.space4

            Label {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                style: VekronaTheme.type.title
                elide: Text.ElideRight
                text: root.card ? root.oneLine(root.result.title) : ""
            }

            Rectangle {
                Layout.preferredWidth: VekronaTheme.borderHair
                Layout.fillHeight: true
                Layout.topMargin: VekronaTheme.space2
                Layout.bottomMargin: VekronaTheme.space2
                color: VekronaTheme.c.line
            }

            Label {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                style: VekronaTheme.type.headline
                elide: Text.ElideRight
                text: root.card ? root.oneLine(root.result.subtitle ?? "") : ""
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: root.moved()
            onClicked: root.clicked()
        }
    }
}

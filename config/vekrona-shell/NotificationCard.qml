import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications
import "Vekrona"

Rectangle {
    id: root

    // Null for a moment after the notification is gone: a list drops the card of a closed notification only when it next
    // lays out. The card reads everything through the properties below, which stay empty then.
    required property Notification notification
    // The centre lets the user select the text and shows all of it; a toast shows a clipped preview.
    property bool selectable: false
    property bool copied: false
    readonly property string summary: notification?.summary ?? ""
    readonly property string body: notification?.body ?? ""
    // Who sent it, as the sender says: a card without it would let any app pose as the system.
    readonly property string appName: notification?.appName ?? ""
    readonly property var actions: notification?.actions ?? []
    readonly property string copyText: [summary, body].filter(part => part !== "").join("\n")
    readonly property string imageSource: {
        const image = notification?.image ?? "";
        const icon = notification?.appIcon ?? "";
        return image !== "" ? image : icon === "" ? "" : icon.startsWith("/") ? icon : Quickshell.iconPath(icon, true);
    }

    // Brings the sender's window forward, then runs the action, if any. Sway does not focus a window for
    // the app itself: Quickshell sends no activation token with the action, and without one Sway ignores
    // the app's focus request.
    function invoke(action: NotificationAction): void {
        const entry = DesktopEntries.byId(notification.desktopEntry);
        Windows.focusApp([notification.desktopEntry, entry?.startupClass ?? "", notification.appName]);
        if (action)
            action.invoke();
    }

    // A click on the card runs the action the app marked as its default, and only that one: the first action of a
    // notification may be Reply, Delete or Accept, which a click that meant to dismiss or read must not run.
    function activate(): void {
        invoke(actions.find(candidate => candidate.identifier === "default") ?? null);
    }

    implicitHeight: content.implicitHeight + 2 * VekronaTheme.space3
    color: VekronaTheme.c.surface1
    border.width: VekronaTheme.borderHair
    border.color: VekronaTheme.c.line

    MouseArea {
        anchors.fill: parent
        onClicked: root.activate()
    }

    HoverHandler {
        onHoveredChanged: {
            if (!hovered)
                root.copied = false;
        }
    }

    RowLayout {
        id: content
        anchors.fill: parent
        anchors.margins: VekronaTheme.space3
        spacing: VekronaTheme.space3

        Image {
            visible: root.imageSource !== ""
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: VekronaTheme.iconM
            Layout.preferredHeight: VekronaTheme.iconM
            sourceSize.width: VekronaTheme.iconM
            sourceSize.height: VekronaTheme.iconM
            source: root.imageSource
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: VekronaTheme.space1

            Label {
                visible: root.appName !== ""
                Layout.fillWidth: true
                style: VekronaTheme.type.caption
                color: VekronaTheme.c.inkMuted
                elide: Text.ElideRight
                text: root.appName
            }

            SelectableLabel {
                visible: root.selectable
                Layout.fillWidth: true
                style: VekronaTheme.type.bodyStrong
                wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                text: root.summary
                onClicked: root.activate()
            }

            Label {
                visible: !root.selectable
                Layout.fillWidth: true
                style: VekronaTheme.type.bodyStrong
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 2
                elide: Text.ElideRight
                text: root.summary
            }

            SelectableLabel {
                visible: root.selectable && root.body !== ""
                Layout.fillWidth: true
                style: VekronaTheme.type.body
                wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                text: root.body
                onClicked: root.activate()
            }

            Label {
                visible: !root.selectable && root.body !== ""
                Layout.fillWidth: true
                style: VekronaTheme.type.body
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 4
                elide: Text.ElideRight
                text: root.body
            }

            Flow {
                visible: root.actions.length > 0
                Layout.fillWidth: true
                spacing: VekronaTheme.space1

                Repeater {
                    model: root.actions

                    BarPill {
                        required property NotificationAction modelData

                        value: modelData.text
                        ariaName: modelData.text
                        onClicked: root.invoke(modelData)
                    }
                }
            }
        }

        BarPill {
            Layout.alignment: Qt.AlignTop
            icon: root.copied ? "check" : "content_copy"
            ariaName: "Copy"
            enabled: root.copyText !== ""
            onClicked: Exec.copy(root.copyText, () => root.copied = true)
        }

        BarPill {
            Layout.alignment: Qt.AlignTop
            icon: "close"
            ariaName: "Dismiss"
            onClicked: root.notification.dismiss()
        }
    }
}

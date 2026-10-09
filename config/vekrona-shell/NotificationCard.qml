import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications
import "Vekrona"

Rectangle {
    id: root

    required property Notification notification
    property int bodyLines: 4
    readonly property string imageSource: notification.image !== "" ? notification.image : notification.appIcon === "" ? "" : notification.appIcon.startsWith("/") ? notification.appIcon : Quickshell.iconPath(notification.appIcon, true)

    function activate(): void {
        const actions = notification.actions;
        const action = actions.find(candidate => candidate.identifier === "default") ?? actions[0];
        if (action)
            action.invoke();
    }

    implicitHeight: content.implicitHeight + 2 * VekronaTheme.space3
    color: VekronaTheme.c.surface1
    border.width: VekronaTheme.borderHair
    border.color: VekronaTheme.c.line

    MouseArea {
        anchors.fill: parent
        onClicked: root.activate()
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
                Layout.fillWidth: true
                style: VekronaTheme.type.bodyStrong
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 2
                elide: Text.ElideRight
                text: root.notification.summary
            }

            Label {
                visible: root.notification.body !== ""
                Layout.fillWidth: true
                style: VekronaTheme.type.body
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: root.bodyLines
                elide: Text.ElideRight
                text: root.notification.body
            }

            Flow {
                visible: root.notification.actions.length > 0
                Layout.fillWidth: true
                spacing: VekronaTheme.space1

                Repeater {
                    model: root.notification.actions

                    BarPill {
                        required property NotificationAction modelData

                        value: modelData.text
                        ariaName: modelData.text
                        onClicked: modelData.invoke()
                    }
                }
            }
        }

        BarPill {
            Layout.alignment: Qt.AlignTop
            icon: "close"
            ariaName: "Dismiss"
            onClicked: root.notification.dismiss()
        }
    }
}

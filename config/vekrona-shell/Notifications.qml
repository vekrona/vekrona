pragma Singleton
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import "Vekrona"

Singleton {
    id: root

    readonly property int defaultTimeoutMs: 5000
    readonly property int maxToasts: 4
    readonly property int cardWidth: 12 * VekronaTheme.sizeTarget
    readonly property var newestFirst: server.trackedNotifications.values.slice().reverse()
    property bool centerOpen: false
    property int unseenCount: 0
    // Ids of the notifications that are off the screen as toasts (timed out or pushed off by newer ones) but still in the centre.
    property var expired: ({})
    readonly property var visibleToasts: server.trackedNotifications.values.filter(notification => !expired[notification.id])
    readonly property bool toasting: !centerOpen && visibleToasts.length > 0

    function expire(notification: Notification): void {
        expired = Object.assign({}, expired, {
            [notification.id]: true
        });
    }

    function forget(notification: Notification): void {
        const next = Object.assign({}, expired);
        delete next[notification.id];
        expired = next;
    }

    // A toast that left the screen never comes back because another one was dismissed, so only the newest maxToasts stay.
    function trimToasts(): void {
        const overflow = server.trackedNotifications.values.filter(notification => !expired[notification.id]).slice(0, -maxToasts);
        if (overflow.length > 0)
            expired = Object.assign({}, expired, ...overflow.map(notification => ({
                        [notification.id]: true
                    })));
    }

    function reshow(notification: Notification): void {
        forget(notification);
        trimToasts();
    }

    function toggleCenter(): void {
        setCenterOpen(!centerOpen);
    }

    function setCenterOpen(open: bool): void {
        centerOpen = open;
        if (open)
            unseenCount = 0;
    }

    function clearAll(): void {
        unseenCount = 0;
        for (const notification of server.trackedNotifications.values.slice())
            notification.dismiss();
    }

    NotificationServer {
        id: server
        actionsSupported: true
        imageSupported: true
        persistenceSupported: true
        bodyMarkupSupported: false
        bodyHyperlinksSupported: false
        onNotification: notification => {
            notification.tracked = true;
            notification.summaryChanged.connect(() => root.reshow(notification));
            notification.bodyChanged.connect(() => root.reshow(notification));
            notification.closed.connect(() => root.forget(notification));
            if (!root.centerOpen)
                root.unseenCount++;
        }
    }

    Connections {
        target: server.trackedNotifications

        function onValuesChanged(): void {
            root.trimToasts();
        }
    }

    IpcHandler {
        target: "notifications"

        function toggle(): void {
            root.toggleCenter();
        }

        function close(): void {
            root.setCenterOpen(false);
        }

        function clearAll(): void {
            root.clearAll();
        }
    }

    PanelWindow {
        visible: root.toasting
        color: "transparent"
        anchors.top: true
        anchors.right: true
        margins.top: VekronaTheme.sizeBar + VekronaTheme.space2
        margins.right: VekronaTheme.space2
        implicitWidth: root.cardWidth
        implicitHeight: toasts.implicitHeight
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "vekrona-toasts"

        ColumnLayout {
            id: toasts
            width: parent.width
            spacing: VekronaTheme.space2

            Repeater {
                model: ScriptModel {
                    values: root.visibleToasts
                }

                NotificationCard {
                    id: toast

                    required property Notification modelData

                    notification: modelData
                    Layout.fillWidth: true

                    Timer {
                        running: notification.urgency !== NotificationUrgency.Critical
                        interval: notification.expireTimeout > 0 ? notification.expireTimeout : root.defaultTimeoutMs
                        onTriggered: root.expire(toast.modelData)
                    }
                }
            }
        }
    }

    Catcher {
        targetScreen: null
        active: root.centerOpen
        onDismissed: root.setCenterOpen(false)
    }

    PanelWindow {
        visible: root.centerOpen
        color: "transparent"
        anchors.top: true
        anchors.right: true
        anchors.bottom: true
        margins.top: VekronaTheme.sizeBar
        implicitWidth: root.cardWidth + 2 * VekronaTheme.space4
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "vekrona-notifications"
        WlrLayershell.keyboardFocus: root.centerOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Rectangle {
            anchors.fill: parent
            color: VekronaTheme.c.surface1
            border.width: VekronaTheme.borderHair
            border.color: VekronaTheme.c.line
        }

        FocusScope {
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.setCenterOpen(false)

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: VekronaTheme.space4
                spacing: VekronaTheme.space2

                RowLayout {
                    Layout.fillWidth: true

                    Label {
                        Layout.fillWidth: true
                        style: VekronaTheme.type.title
                        text: "Notifications"
                    }

                    BarPill {
                        visible: root.newestFirst.length > 0
                        value: "Clear all"
                        ariaName: "Clear all notifications"
                        onClicked: root.clearAll()
                    }
                }

                Label {
                    visible: root.newestFirst.length === 0
                    style: VekronaTheme.type.body
                    color: VekronaTheme.c.inkMuted
                    text: "No notifications"
                }

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: VekronaTheme.space2
                    model: ScriptModel {
                        values: root.newestFirst
                    }

                    delegate: NotificationCard {
                        required property Notification modelData

                        width: ListView.view.width
                        notification: modelData
                        bodyLines: 10
                    }
                }
            }
        }
    }
}

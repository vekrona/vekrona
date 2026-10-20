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
    // Ids grow with arrival, so the notifications newer than the last one the user saw are the unseen ones.
    property int seenUpTo: 0
    readonly property int unseenCount: centerOpen ? 0 : server.trackedNotifications.values.filter(notification => notification.id > seenUpTo).length
    // Ids of the notifications that are off the screen as toasts (timed out or pushed off by newer ones) but still in the centre.
    // Changed in place, so a flood of notifications does not copy it for each; `expiredRevision` tells the bindings that it changed.
    readonly property var expired: ({})
    property int expiredRevision: 0
    readonly property var visibleToasts: unexpired(expiredRevision)
    readonly property bool toasting: !centerOpen && visibleToasts.length > 0

    // The notifications that are not in `expired`. The revision is a parameter only so that a binding that calls this follows it.
    function unexpired(revision: int): var {
        return server.trackedNotifications.values.filter(notification => !expired[notification.id]);
    }

    function expireAll(notifications: var): void {
        if (notifications.length === 0)
            return;
        for (const notification of notifications)
            expired[notification.id] = true;
        expiredRevision++;
    }

    function expire(notification: Notification): void {
        expireAll([notification]);
    }

    function forget(notification: Notification): void {
        if (!(notification.id in expired))
            return;
        delete expired[notification.id];
        expiredRevision++;
    }

    // A toast that left the screen never comes back because another one was dismissed, so only the newest maxToasts stay.
    function trimToasts(): void {
        const tracked = server.trackedNotifications.values;
        const stale = [];
        let shown = 0;
        for (let i = tracked.length - 1; i >= 0; i--) {
            if (!expired[tracked[i].id] && ++shown > maxToasts)
                stale.push(tracked[i]);
        }
        expireAll(stale);
    }

    // A new or changed notification toasts again, unless the centre is open: it lists everything already, and a toast
    // hidden behind it would pop up when the centre closes.
    function reshow(notification: Notification): void {
        if (centerOpen)
            expire(notification);
        else
            forget(notification);
        trimToasts();
    }

    function toggleCenter(): void {
        setCenterOpen(!centerOpen);
    }

    function markSeen(): void {
        seenUpTo = Math.max(seenUpTo, ...server.trackedNotifications.values.map(notification => notification.id));
    }

    function setCenterOpen(open: bool): void {
        centerOpen = open;
        if (open) {
            KeyboardSurface.claim(root);
            expireAll(server.trackedNotifications.values);
        }
        markSeen();
    }

    function clearAll(): void {
        markSeen();
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
            root.reshow(notification);
            notification.summaryChanged.connect(() => root.reshow(notification));
            notification.bodyChanged.connect(() => root.reshow(notification));
            notification.closed.connect(() => root.forget(notification));
        }
    }

    // The launcher or a popout came up and holds the keyboard now.
    Connections {
        target: KeyboardSurface

        function onClaimed(owner: var): void {
            if (owner !== root && root.centerOpen)
                root.setCenterOpen(false);
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
        // Opaque, so the gaps between the cards are the card colour, not the desktop.
        color: VekronaTheme.c.surface1
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
        color: VekronaTheme.c.surface1
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
            color: "transparent"
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

                // A ListView, so a flood of notifications builds only the cards in view. It drops the card of a dismissed
                // notification when it next lays out, by which time the notification is destroyed: the card reads it through
                // properties that are empty then.
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: VekronaTheme.space2
                    boundsBehavior: Flickable.StopAtBounds
                    model: ScriptModel {
                        values: root.newestFirst
                    }

                    delegate: NotificationCard {
                        required property Notification modelData

                        width: ListView.view.width
                        notification: modelData
                        selectable: true
                    }
                }
            }
        }
    }
}

import QtCore
import Quickshell.Io
import "Vekrona"
import "."

BarPill {
    id: root

    readonly property string unreadPath: StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/vekrona/errors/unread"
    property int unreadCount: 0

    function parseUnread(raw) {
        const n = parseInt(String(raw).trim(), 10);
        return (Number.isFinite(n) && n > 0) ? n : 0;
    }

    icon: "smart_toy"
    ariaName: "Open coding agent"
    overhang: badge.visible ? badge.width - VekronaTheme.space1 : 0
    onClicked: Exec.detached(["vekrona-agent", "--pick"])
    onRightClicked: Exec.detached(["vekrona-error", "pick"])

    Badge {
        id: badge
        count: root.unreadCount
    }

    FileView {
        path: root.unreadPath
        watchChanges: true
        onLoaded: root.unreadCount = root.parseUnread(text())
        onLoadFailed: root.unreadCount = 0
        onFileChanged: reload()
    }
}

import "Vekrona"

BarPill {
    required property var launcher

    icon: "smart_toy"
    ariaName: "Toggle error list"
    badgeCount: Errors.unreadCount
    badgeDimmed: Errors.dim
    onClicked: launcher.toggleMode("agent")
}

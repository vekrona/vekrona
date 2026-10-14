import "Vekrona"
import "."

BarPill {
    icon: "notifications"
    ariaName: "Notifications"
    badgeCount: Notifications.unseenCount
    onClicked: Notifications.toggleCenter()
}

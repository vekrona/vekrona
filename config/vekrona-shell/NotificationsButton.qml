import "Vekrona"
import "."

BarPill {
    icon: "notifications"
    ariaName: "Notifications"
    onClicked: Notifications.toggleCenter()

    Badge {
        dot: true
        count: Notifications.unseen ? 1 : 0
    }
}

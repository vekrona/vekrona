import Quickshell
import "Vekrona"

BarPill {
    ariaName: "Clock"
    value: Qt.formatDateTime(clock.date, "ddd d MMM HH:mm")

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }
}

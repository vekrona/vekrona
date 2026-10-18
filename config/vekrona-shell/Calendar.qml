import QtQuick
import QtQuick.Layouts
import Quickshell
import "Vekrona"

Row {
    id: root

    required property var bar
    // How old the agenda may be when the popout opens before it is synced again, in milliseconds.
    readonly property int refreshAgeMs: 10 * 60 * 1000
    readonly property int labelMaxChars: 24
    readonly property int agendaMaxHeight: VekronaTheme.sizeTarget * 8
    readonly property var calendar: file.value
    readonly property var events: calendar?.events ?? []
    readonly property date today: new Date(clock.date.getFullYear(), clock.date.getMonth(), clock.date.getDate())
    readonly property var upcoming: nextEvent(events, clock.date)

    function parse(stamp: string): date {
        const [year, month, day] = stamp.slice(0, 10).split("-").map(Number);
        const [hour, minute] = stamp.length > 10 ? stamp.slice(11).split(":").map(Number) : [0, 0];
        return new Date(year, month - 1, day, hour, minute);
    }

    function nextEvent(list, now: date) {
        const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
        return list.find(event => !event.allDay && parse(event.end) > now && parse(event.start) < midnight) ?? null;
    }

    function elide(text: string): string {
        return text.length > labelMaxChars ? text.slice(0, labelMaxChars - 1) + "…" : text;
    }

    function byDay(list) {
        const days = [];
        for (const event of list) {
            const day = event.start.slice(0, 10);
            if (days.length === 0 || days[days.length - 1].day !== day)
                days.push({ day: day, events: [] });
            days[days.length - 1].events.push(event);
        }
        return days;
    }

    BarPill {
        visible: root.upcoming !== null
        value: root.upcoming ? root.elide(root.upcoming.start.slice(11) + " " + root.upcoming.title) : ""
        ariaName: "Next event"
        onClicked: root.bar.togglePopout(popout)
    }

    BarPill {
        id: dateTime
        value: Qt.formatDateTime(clock.date, "ddd d MMM HH:mm")
        widestValue: "Wed 28 May 28:28"
        ariaName: "Calendar"
        onClicked: root.bar.togglePopout(popout)
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    StateFile {
        id: file
        path: StateDir.path + "/calendar.json"
    }

    Popout {
        id: popout
        anchorItem: dateTime
        open: root.bar.openPopout === popout
        onDismissed: root.bar.openPopout = null
        onOpenChanged: {
            if (open)
                Exec.refreshService("vekrona-calendar.service", root.refreshAgeMs);
            else
                month.monthOffset = 0;
        }

        MonthGrid {
            id: month
            Layout.preferredWidth: VekronaTheme.sizeTarget * 10
            today: root.today
            highlighted: root.today
        }

        Label {
            visible: root.calendar?.configured === false
            Layout.maximumWidth: VekronaTheme.sizeTarget * 10
            wrapMode: Text.Wrap
            color: VekronaTheme.c.inkMuted
            style: VekronaTheme.type.body
            text: "No calendars yet. See docs/calendar.md."
        }

        Label {
            visible: root.calendar?.configured === true && root.events.length === 0
            color: VekronaTheme.c.inkMuted
            style: VekronaTheme.type.body
            text: "No events in the next 31 days."
        }

        Flickable {
            visible: root.events.length > 0
            Layout.preferredWidth: VekronaTheme.sizeTarget * 10
            Layout.preferredHeight: Math.min(agenda.implicitHeight, root.agendaMaxHeight)
            contentWidth: width
            contentHeight: agenda.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            ColumnLayout {
                id: agenda
                width: parent.width
                spacing: VekronaTheme.space2

                Repeater {
                    model: root.byDay(root.events)

                    ColumnLayout {
                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 0

                        Label {
                            style: VekronaTheme.type.bodyStrong
                            text: Qt.formatDate(root.parse(modelData.day), "ddd d MMM")
                        }

                        Repeater {
                            model: modelData.events

                            RowLayout {
                                required property var modelData

                                Layout.fillWidth: true
                                spacing: VekronaTheme.space2

                                Label {
                                    Layout.preferredWidth: VekronaTheme.sizeTarget * 2
                                    color: VekronaTheme.c.inkMuted
                                    style: VekronaTheme.type.body
                                    text: modelData.allDay ? "All day" : modelData.start.slice(11)
                                }

                                Label {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    style: VekronaTheme.type.body
                                    text: modelData.title
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

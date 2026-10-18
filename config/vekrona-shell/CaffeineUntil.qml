import QtQuick
import QtQuick.Layouts
import "Vekrona"

// Picks a day and a time of day for a session that ends at a time. The day comes from a month grid that opens under the
// day pill. The time is typed as HH:MM, H:MM or HHMM; Up and Down or the wheel step it by minutes.
ColumnLayout {
    id: root

    readonly property int minuteStep: 5
    // The last day on offer, counted from today.
    readonly property int maxDays: 30
    // Whether the menu is open: the clock below only runs then.
    property bool open: false
    // Whether the month grid is shown. The menu decides, because it shows one list at a time.
    property bool picking: false
    // The midnight that the day is counted from, and the time now, which decides whether the choice is already past.
    property var today: new Date()
    property var now: new Date()
    // The one value the pickers show and change. A step carries into the larger parts, so 23:55 Up is 00:00 tomorrow.
    property var chosen: new Date()
    // The chosen day with the time the field holds, or null when the field holds no time of day.
    readonly property var typed: typedTime(timeField.text)
    // Why the choice cannot start a session, or "" when it can.
    readonly property string problem: typed === null ? "Type a time as HH:MM, from 00:00 to 23:59" : typed <= now ? "That time is past" : ""

    // Emitted with the choice as `YYYY-MM-DD HH:MM`.
    signal picked(string stamp)
    // Emitted when the day pill or a picked day asks the menu to show or hide the month grid.
    signal pickerRequested(bool shown)

    // How many calendar days a date is after today.
    function daysFromToday(date: var): int {
        return Math.round((Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) - Date.UTC(today.getFullYear(), today.getMonth(), today.getDate())) / 86400000);
    }

    function pad(number: int): string {
        return String(number).padStart(2, "0");
    }

    function dayName(date: var): string {
        const offset = daysFromToday(date);
        return offset === 0 ? "Today" : offset === 1 ? "Tomorrow" : Qt.formatDate(date, "ddd d MMM");
    }

    function timeText(date: var): string {
        return pad(date.getHours()) + ":" + pad(date.getMinutes());
    }

    function stamp(): string {
        return chosen.getFullYear() + "-" + pad(chosen.getMonth() + 1) + "-" + pad(chosen.getDate()) + " " + timeText(chosen);
    }

    // The chosen day at the time of day in `text`, or null when `text` is none.
    function typedTime(text: string): var {
        const match = /^(\d{1,2}):?(\d{2})$/.exec(text.trim());
        if (match === null || Number(match[1]) > 23 || Number(match[2]) > 59)
            return null;
        return new Date(chosen.getFullYear(), chosen.getMonth(), chosen.getDate(), Number(match[1]), Number(match[2]));
    }

    // Takes the choice to `date` and writes its time into the field.
    function show(date: var): void {
        chosen = date;
        timeField.text = timeText(date);
    }

    // Reads the clock again: a menu left open past midnight counts its days from the new day.
    function tick(): void {
        now = new Date();
        today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    }

    // Goes back to the next whole hour.
    function reset(): void {
        tick();
        show(new Date(now.getFullYear(), now.getMonth(), now.getDate(), now.getHours() + 1));
    }

    // Moves the choice by whole days, hours and minutes, and keeps it where it is when the move would leave today or the
    // last day on offer.
    function step(days: int, hours: int, minutes: int): void {
        const target = new Date(chosen.getFullYear(), chosen.getMonth(), chosen.getDate() + days, chosen.getHours() + hours, chosen.getMinutes() + minutes);
        const offset = daysFromToday(target);
        if (offset >= 0 && offset <= maxDays)
            show(target);
    }

    // Moves the choice to another day at the same time, and hides the month grid.
    function pickDay(day: date): void {
        chosen = new Date(day.getFullYear(), day.getMonth(), day.getDate(), chosen.getHours(), chosen.getMinutes());
        pickerRequested(false);
    }

    function startIfAllowed(): void {
        if (problem === "")
            picked(stamp());
    }

    onPickingChanged: if (picking)
        month.showMonthOf(chosen)

    spacing: 0

    RowLayout {
        Layout.fillWidth: true
        spacing: VekronaTheme.space1

        BarPill {
            icon: "event"
            value: root.dayName(root.chosen)
            widestValue: ["Tomorrow", "Wed 28 May"]
            emphasized: root.picking
            ariaName: "Day, " + value
            onClicked: root.pickerRequested(!root.picking)
            onWheel: delta => root.step(delta > 0 ? 1 : -1, 0, 0)
            Keys.onUpPressed: root.step(1, 0, 0)
            Keys.onDownPressed: root.step(-1, 0, 0)
        }

        TextField {
            id: timeField
            Layout.preferredWidth: VekronaTheme.sizeTarget * 2
            activeFocusOnTab: true
            placeholder: "HH:MM"
            accessibleName: "Time, HH:MM"
            borderColor: root.problem === "" ? colors.line : colors.dangerInk
            onTextEdited: {
                const time = root.typedTime(text);
                if (time !== null)
                    root.chosen = time;
            }
            onAccepted: root.startIfAllowed()
            onKeyPressed: event => {
                if (event.key !== Qt.Key_Up && event.key !== Qt.Key_Down)
                    return;
                root.step(0, 0, (event.key === Qt.Key_Up ? 1 : -1) * root.minuteStep);
                event.accepted = true;
            }

            WheelHandler {
                onWheel: event => root.step(0, 0, (event.angleDelta.y > 0 ? 1 : -1) * root.minuteStep)
            }
        }

        BarPill {
            Layout.fillWidth: true
            icon: "play_arrow"
            value: "Start"
            enabled: root.problem === ""
            ariaName: enabled ? "Stay awake until " + root.stamp() : "Stay awake until, " + root.problem
            onClicked: root.startIfAllowed()
        }
    }

    Label {
        visible: root.problem !== ""
        Layout.fillWidth: true
        Layout.leftMargin: VekronaTheme.space2
        Layout.topMargin: VekronaTheme.space1
        wrapMode: Text.Wrap
        style: VekronaTheme.type.caption
        color: VekronaTheme.c.dangerInk
        text: root.problem
    }

    MonthGrid {
        id: month
        visible: root.picking
        Layout.fillWidth: true
        Layout.topMargin: VekronaTheme.space2
        today: root.today
        highlighted: root.chosen
        earliest: root.today
        latest: new Date(root.today.getFullYear(), root.today.getMonth(), root.today.getDate() + root.maxDays)
        interactive: true
        onPicked: day => root.pickDay(day)
    }

    Timer {
        interval: 30000
        repeat: true
        running: root.open
        onTriggered: root.tick()
    }
}

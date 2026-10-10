pragma Singleton
import QtQuick
import Quickshell
import Quickshell.I3
import "."

// The keyboard layouts as Sway has them; Sway stays the source of truth and is re-read on every input event.
Singleton {
    id: root

    // [{id, code, name}], in Sway's layout order.
    property var layouts: []
    property int activeIndex: -1
    property bool available: false
    // Why the last query or switch failed; empty after the next successful query.
    property string error: ""
    // Set by a switch the shell starts itself (the menu, a right click), which the person is already looking at.
    property bool quiet: false

    // The active layout changed from outside the shell (Hyper+Space, swaymsg), after the new layout is known.
    signal switched()

    readonly property var current: activeIndex >= 0 && activeIndex < layouts.length ? layouts[activeIndex] : null

    // Known layouts by xkb id: the code the bar shows, the endonym the menu shows, and Sway's name for that id.
    readonly property var known: ({
            us: { code: "EN", name: "English (US)", sway: "English (US)" },
            gb: { code: "EN", name: "English (UK)", sway: "English (UK)" },
            ua: { code: "UA", name: "Українська", sway: "Ukrainian" },
            de: { code: "DE", name: "Deutsch", sway: "German" },
            fr: { code: "FR", name: "Français", sway: "French" },
            es: { code: "ES", name: "Español", sway: "Spanish" },
            pl: { code: "PL", name: "Polski", sway: "Polish" },
            ru: { code: "RU", name: "Русский", sway: "Russian" }
        })

    function idForSwayName(swayName: string): string {
        for (const id in known)
            if (known[id].sway === swayName)
                return id;
        return "";
    }

    function layoutFor(id: string, swayName: string): var {
        const entry = known[id];
        if (entry)
            return { id: id, code: entry.code, name: entry.name };
        return { id: id, code: (id || swayName).substring(0, 2).toUpperCase(), name: swayName };
    }

    function apply(inputs: var): void {
        // Every keyboard carries the same keymap; the one with the most layouts is the real one, not a single-layout virtual device.
        let keyboard = null;
        for (const input of inputs)
            if (input.type === "keyboard" && (input.xkb_layout_names?.length ?? 0) > (keyboard?.xkb_layout_names.length ?? 0))
                keyboard = input;
        if (!keyboard) {
            available = false;
            fail("Sway reports no keyboard with a layout");
            return;
        }
        const names = keyboard.xkb_layout_names;
        // XKB_DEFAULT_LAYOUT holds the ids Sway started with; a keymap changed later by swaymsg no longer lines up with it.
        const env = Quickshell.env("XKB_DEFAULT_LAYOUT");
        const envIds = env ? String(env).split(",").map(id => id.trim()) : [];
        const lined = envIds.length === names.length;
        const fresh = names.map((name, index) => layoutFor(lined ? envIds[index] : idForSwayName(name), name));
        // A switch reports the same list once per keyboard device; a new array would make every Repeater over it rebuild its rows
        // and resize the menu and the on-screen display mid-frame, so only a changed list is assigned.
        const sameList = JSON.stringify(fresh) === JSON.stringify(layouts);
        if (!sameList)
            layouts = fresh;
        const index = keyboard.xkb_active_layout_index ?? 0;
        const moved = sameList && activeIndex >= 0 && index !== activeIndex;
        activeIndex = index;
        available = true;
        error = "";
        if (!moved)
            return;
        if (quiet)
            quiet = false;
        else
            switched();
    }

    function fail(reason: string): void {
        error = reason;
        console.error("Keyboard: " + reason);
    }

    function query(): void {
        const argv = ["swaymsg", "-t", "get_inputs", "--raw"];
        Exec.run(argv, (code, stdout, stderr) => {
            if (code !== 0) {
                available = false;
                fail(Exec.failure(argv, code, stderr));
                return;
            }
            let inputs;
            try {
                inputs = JSON.parse(stdout);
            } catch (e) {
                available = false;
                fail("swaymsg -t get_inputs printed invalid JSON: " + e);
                return;
            }
            apply(inputs);
        });
    }

    // `layout` is an index or "next"; Sway's input event then refreshes `activeIndex`.
    function switchTo(layout: string): void {
        const argv = ["swaymsg", "input", "type:keyboard", "xkb_switch_layout", layout];
        quiet = true;
        Exec.run(argv, (code, stdout, stderr) => {
            if (code !== 0) {
                quiet = false;
                fail(Exec.failure(argv, code, stderr));
            }
        });
    }

    function select(index: int): void {
        // Picking the current layout changes nothing, so no event would clear `quiet`.
        if (index !== activeIndex)
            switchTo(String(index));
    }

    function next(): void {
        switchTo("next");
    }

    Component.onCompleted: query()

    I3IpcListener {
        subscriptions: ["input"]
        onIpcEvent: root.query()
    }
}

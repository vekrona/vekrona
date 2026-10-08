// The Vekrona Design System for Quickshell apps. vekrona-render-theme writes
// $XDG_STATE_HOME/vekrona/active-theme.json from config/tokens.json; this
// singleton exposes it and follows every rewrite. Consumers symlink this
// directory as config/<app>/Vekrona and `import "Vekrona"`.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    component Palette: QtObject {
        required property var tokens

        readonly property color bg: tokens.bg
        readonly property color surface1: tokens.surface1
        readonly property color surface2: tokens.surface2
        readonly property color surface3: tokens.surface3
        readonly property color ink: tokens.ink
        readonly property color inkMuted: tokens.inkMuted
        readonly property color inkDisabled: tokens.inkDisabled
        readonly property color line: tokens.line
        readonly property color lineStrong: tokens.lineStrong
        readonly property color accent: tokens.accent
        readonly property color onAccent: tokens.onAccent
        readonly property color accentInk: tokens.accentInk
        readonly property color focus: tokens.focus
        readonly property color danger: tokens.danger
        readonly property color onDanger: tokens.onDanger
        readonly property color dangerInk: tokens.dangerInk
        readonly property color warning: tokens.warning
        readonly property color onWarning: tokens.onWarning
        readonly property color success: tokens.success
        readonly property color onSuccess: tokens.onSuccess
        readonly property color info: tokens.info
        readonly property color onInfo: tokens.onInfo
        readonly property color scrim: tokens.scrim
    }

    readonly property string path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/vekrona/active-theme.json"

    // Fallback used only when active-theme.json cannot be loaded: one
    // monochrome palette (the only literals in this module) and plain metrics.
    readonly property var fallback: {
        const mono = {
            bg: "black", surface1: "black", surface2: "black", surface3: "black",
            ink: "white", inkMuted: "white", inkDisabled: "white",
            line: "white", lineStrong: "white",
            accent: "white", onAccent: "black", accentInk: "white", focus: "white",
            danger: "white", onDanger: "black", dangerInk: "white",
            warning: "white", onWarning: "black", success: "white", onSuccess: "black",
            info: "white", onInfo: "black", scrim: "black"
        };
        const style = (size, line, weight) => ({ size: size, line: line, weight: weight, tracking: 0 });
        return {
            mode: "dark",
            metrics: {
                spacing: { space1: 4, space2: 8, space3: 12, space4: 16, space6: 24, space8: 32 },
                border: { hair: 1, control: 1, focus: 1, indicator: 2, focusOffset: 2 },
                size: { target: 32, bar: 36, iconS: 18, iconM: 24, iconL: 48, iconXl: 72 },
                opacity: { scrim: 0.6 },
                motion: { fast: 120, popover: 200 },
                font: { sans: ["sans-serif"], mono: ["monospace"], icon: "Material Symbols Rounded" },
                type: {
                    display: style(32, 36, 700), headline: style(22, 28, 600), title: style(18, 24, 600),
                    body: style(15, 22, 400), bodyStrong: style(15, 22, 600), label: style(13, 18, 600),
                    caption: style(13, 18, 400), mono: style(14, 20, 400)
                }
            },
            dark: { tokens: mono },
            light: { tokens: mono }
        };
    }

    // The names of the parts the bindings below read that doc lacks.
    function missingParts(doc: var): var {
        const missing = [];
        if (doc === null || typeof doc !== "object")
            return ["a JSON object"];
        if (!doc.metrics)
            missing.push("metrics");
        for (const mode of ["dark", "light"]) {
            if (!doc[mode] || !doc[mode].tokens)
                missing.push(mode + ".tokens");
        }
        return missing;
    }

    function parse(text: string): var {
        // An empty text means the load failed, which view.onLoadFailed reported.
        if (text === "")
            return fallback;
        let doc;
        try {
            doc = JSON.parse(text);
        } catch (e) {
            console.error("VekronaTheme: " + path + " is not valid JSON:", e);
            return fallback;
        }
        const missing = missingParts(doc);
        if (missing.length > 0) {
            console.error("VekronaTheme: " + path + " lacks " + missing.join(", ") + "; run vekrona-render-theme");
            return fallback;
        }
        return doc;
    }

    // Reading text() blocks until the first load, so the first paint has colors;
    // the binding re-runs whenever the watched file is reloaded.
    readonly property var doc: parse(view.text())

    FileView {
        id: view
        path: root.path
        blockLoading: true
        watchChanges: true
        // The renderer replaces the file with a rename; FileView re-arms its
        // watch on the new file and emits fileChanged for it.
        onFileChanged: reload()
        onLoadFailed: error => console.error("VekronaTheme: cannot read " + root.path + ":", error)
    }

    readonly property string mode: doc.mode
    readonly property Palette dark: Palette { tokens: root.doc.dark.tokens }
    readonly property Palette light: Palette { tokens: root.doc.light.tokens }
    readonly property Palette c: mode === "light" ? light : dark

    readonly property int space1: doc.metrics.spacing.space1
    readonly property int space2: doc.metrics.spacing.space2
    readonly property int space3: doc.metrics.spacing.space3
    readonly property int space4: doc.metrics.spacing.space4
    readonly property int space6: doc.metrics.spacing.space6
    readonly property int space8: doc.metrics.spacing.space8

    readonly property int borderHair: doc.metrics.border.hair
    readonly property int borderControl: doc.metrics.border.control
    readonly property int borderFocus: doc.metrics.border.focus
    readonly property int borderIndicator: doc.metrics.border.indicator
    readonly property int focusOffset: doc.metrics.border.focusOffset

    readonly property int sizeTarget: doc.metrics.size.target
    readonly property int sizeBar: doc.metrics.size.bar
    readonly property int iconS: doc.metrics.size.iconS
    readonly property int iconM: doc.metrics.size.iconM
    readonly property int iconL: doc.metrics.size.iconL
    readonly property int iconXl: doc.metrics.size.iconXl

    readonly property real scrimOpacity: doc.metrics.opacity.scrim
    readonly property int motionFast: doc.metrics.motion.fast
    readonly property int motionPopover: doc.metrics.motion.popover

    readonly property string fontSans: doc.metrics.font.sans[0]
    readonly property string fontMono: doc.metrics.font.mono[0]
    readonly property string fontIcon: doc.metrics.font.icon

    // type.<style>.{size,line,weight,tracking}
    readonly property var type: doc.metrics.type

    // Material Symbols ligature text; set it on a Text whose font.family is fontIcon.
    function icon(name: string): string {
        return name;
    }
}

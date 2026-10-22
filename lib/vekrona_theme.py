"""Loads, flattens and validates config/tokens.json (the Vekrona Design System export).

The single place that knows the token names and the unit conversions.
Every failure raises ThemeError naming the offending token.
"""
import json
import re

MODES = ("dark", "light")

COLOR_NAMES = (
    "bg", "surface-1", "surface-2", "surface-3", "ink", "ink-muted", "ink-disabled", "line", "line-strong",
    "accent", "on-accent", "accent-ink", "focus", "focus-inner", "selected", "danger", "on-danger", "danger-ink",
    "warning", "on-warning", "success", "on-success", "info", "on-info",
)
# Metric group -> (prefix stripped from the token name, required token names). The result is camelCased.
METRIC_GROUPS = {
    "spacing": ("", ("space-1", "space-2", "space-3", "space-4", "space-6", "space-8")),
    "border": ("border-", ("border-hair", "border-control", "border-focus")),
    "size": ("size-", ("size-target", "size-bar", "size-icon-s", "size-icon-m", "size-icon-l", "size-icon-xl")),
}
TYPE_STYLES = ("display", "headline", "title", "body", "body-strong", "label", "caption", "mono")
FAMILIES = ("sans", "mono", "icons")
GENERIC_FAMILIES = ("system-ui", "sans-serif", "ui-monospace", "monospace")

# Design rules the tokens state only in prose ("120 ms ... 200 ms").
MOTION_MS = {"fast": 120, "popover": 200}

# Matched with fullmatch: "$" would also accept a trailing newline.
HEX_COLOR = re.compile(r"#[0-9a-f]{6}")
PX = re.compile(r"([0-9]+)px")
EM = re.compile(r"(-?[0-9]+(?:\.[0-9]+)?)em")


class ThemeError(Exception):
    pass


def camel(name):
    head, *rest = name.split("-")
    return head + "".join(part.capitalize() for part in rest)


def px_to_pt(px):
    return px * 0.75


def fmt_pt(pt):
    return f"{pt:g}"


def _px(token, value):
    match = PX.fullmatch(value) if isinstance(value, str) else None
    if not match:
        raise ThemeError(f"token {token}: '{value}' is not a size like 16px")
    return int(match.group(1))


def _tracking(token, value):
    if value is None:
        return 0
    match = EM.fullmatch(value) if isinstance(value, str) else None
    if not match:
        raise ThemeError(f"token {token}: letterSpacing '{value}' is not like 0.02em")
    number = float(match.group(1))
    return int(number) if number == int(number) else number


def _named(items, what, wanted):
    """Index a list of {name, ...} entries by name and require every wanted name."""
    if not isinstance(items, list):
        raise ThemeError(f"{what} is not a list")
    index = {item.get("name"): item for item in items if isinstance(item, dict)}
    for name in wanted:
        if name not in index:
            raise ThemeError(f"token {name} is missing from {what}")
    return index


def _families(raw, name):
    value = raw.get(name) if isinstance(raw, dict) else None
    if not isinstance(value, str):
        raise ThemeError(f"type.families.{name} is missing or not a string")
    families = [part.strip().strip('"') for part in value.split(",")]
    families = [family for family in families if family and family not in GENERIC_FAMILIES]
    if not families:
        raise ThemeError(f"type.families.{name} lists no concrete family: {value}")
    return families


class Theme:
    """colors[mode][token-name] -> '#rrggbb'; metrics follows the active-theme.json contract."""

    def __init__(self, colors, metrics, families):
        self.colors = colors
        self.metrics = metrics
        self.families = families

    def sans(self):
        return self.families["sans"][0]

    def mono(self):
        return self.families["mono"][0]

    def type_px(self, style):
        return self.metrics["type"][camel(style)]["size"]

    def active_theme(self, mode):
        """The generated active-theme.json document: both modes plus the metrics."""
        doc = {"name": "Vekrona", "mode": mode, "metrics": self.metrics}
        for each in MODES:
            doc[each] = {"tokens": {camel(name): value for name, value in self.colors[each].items()}}
        return doc


def load(path):
    try:
        with open(path) as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ThemeError(f"could not read {path}: {e}") from e
    try:
        return _build(raw)
    except ThemeError as e:
        raise ThemeError(f"{path}: {e}") from e
    except (KeyError, TypeError, AttributeError) as e:
        raise ThemeError(f"{path}: unexpected structure ({type(e).__name__}: {e})") from e


def _build(raw):
    color_index = _named(raw["color"]["tokens"], "color.tokens", COLOR_NAMES)
    colors = {mode: {} for mode in MODES}
    for name in COLOR_NAMES:
        values = color_index[name].get("value")
        for mode in MODES:
            value = values.get(mode) if isinstance(values, dict) else None
            if not isinstance(value, str) or not HEX_COLOR.fullmatch(value.lower()):
                raise ThemeError(f"token {name}: {mode} value is missing or not a #rrggbb color: {value!r}")
            colors[mode][name] = value.lower()

    metrics = {}
    for group, (prefix, names) in METRIC_GROUPS.items():
        index = _named(raw[group]["tokens"], f"{group}.tokens", names)
        metrics[group] = {camel(name.removeprefix(prefix)): _px(name, index[name].get("value")) for name in names}
    metrics["motion"] = dict(MOTION_MS)

    families = {name: _families(raw["type"]["families"], name) for name in FAMILIES}
    metrics["font"] = {"sans": families["sans"], "mono": families["mono"], "icon": families["icons"][0]}

    all_styles = [style for group in raw["type"]["groups"] for style in group["styles"]]
    style_index = _named(all_styles, "type.groups[].styles", TYPE_STYLES)
    metrics["type"] = {}
    for name in TYPE_STYLES:
        style = style_index[name]
        weight = style.get("fontWeight")
        if isinstance(weight, bool) or not isinstance(weight, int):
            raise ThemeError(f"token {name}: fontWeight {weight!r} is not an integer")
        metrics["type"][camel(name)] = {
            "size": _px(name, style.get("fontSize")), "line": _px(name, style.get("lineHeight")),
            "weight": weight, "tracking": _tracking(name, style.get("letterSpacing")),
        }
    return Theme(colors, metrics, families)

from dataclasses import dataclass
from enum import Enum

from pyanaconda.core.i18n import _

from vekrona_signin.core.device_description import DeviceDescription
from vekrona_signin.gui.spokes import guidance

__all__ = [
    "FINGERPRINT_PANEL",
    "KEY_PANEL",
    "PIN_MIN_LENGTH",
    "PanelInput",
    "PanelView",
    "PinForm",
    "panel_view",
    "pin_form",
]

PIN_MIN_LENGTH = 4


@dataclass(frozen=True)
class PanelKind:
    none_text: str
    found_text: str
    done_text: str
    hint_text: object


KEY_PANEL = PanelKind(
    none_text=guidance.KEY_NONE,
    found_text=guidance.KEY_FOUND,
    done_text=guidance.KEY_DONE,
    hint_text=guidance.device_scan_hint_to_key_text,
)

FINGERPRINT_PANEL = PanelKind(
    none_text=guidance.FP_NONE,
    found_text=guidance.FP_FOUND,
    done_text=guidance.FP_DONE,
    hint_text=guidance.device_scan_hint_to_fp_text,
)


@dataclass(frozen=True)
class PanelInput:
    scan: object = None
    scan_error: str = ""
    selected_id: object = None
    registered: bool = False
    password_valid: bool = False
    busy: bool = False
    watch_available: bool = True
    user_changed: bool = False


@dataclass(frozen=True)
class PanelView:
    state_text: str
    details_text: str
    devices: tuple
    show_setup: bool
    show_registered: bool
    choose_sensitive: bool
    enroll_sensitive: bool
    check_sensitive: bool
    remove_sensitive: bool


def _devices(panel_input):
    if panel_input.scan is None or panel_input.scan_error:
        return ()
    return tuple(
        (device.id, device.name)
        for device in DeviceDescription.from_structure_list(panel_input.scan.devices)
    )


def _device_state(kind, panel_input, devices):
    if panel_input.registered:
        return _(kind.done_text)
    if panel_input.scan_error:
        return _(guidance.SCAN_FAILED).format(error=panel_input.scan_error)
    if panel_input.scan is None:
        return _(guidance.SCANNING)
    if devices:
        names = dict(devices)
        name = names.get(panel_input.selected_id, devices[0][1])
        return _(kind.found_text).format(name=name)
    return kind.hint_text(panel_input.scan.hint_code) or _(kind.none_text)


def _state_text(kind, panel_input, devices):
    lines = []
    if panel_input.user_changed:
        lines.append(_(guidance.USER_CHANGED))
    lines.append(_device_state(kind, panel_input, devices))
    if not panel_input.registered and not panel_input.password_valid:
        lines.append(_(guidance.NEED_PASSWORD_FIRST))
    if not panel_input.watch_available:
        lines.append(_(guidance.WATCH_UNAVAILABLE))
    return "\n".join(lines)


def _details_text(panel_input):
    lines = []
    scan = panel_input.scan
    if scan is not None and not panel_input.scan_error:
        if scan.usb_seen:
            lines.append(_(guidance.DETAILS_USB_SEEN))
            lines.extend(f"  {device}" for device in scan.usb_seen)
        else:
            lines.append(_(guidance.DETAILS_NO_USB))
        if scan.problem:
            lines.append(_(guidance.DETAILS_PROBLEM).format(problem=scan.problem))
    if panel_input.scan_error:
        lines.append(_(guidance.DETAILS_PROBLEM).format(problem=panel_input.scan_error))
    return "\n".join(lines)


def panel_view(kind, panel_input):
    devices = _devices(panel_input)
    idle = not panel_input.busy
    can_set_up = idle and not panel_input.registered
    has_selection = panel_input.selected_id in dict(devices)
    return PanelView(
        state_text=_state_text(kind, panel_input, devices),
        details_text=_details_text(panel_input),
        devices=devices,
        show_setup=not panel_input.registered,
        show_registered=panel_input.registered,
        choose_sensitive=can_set_up and bool(devices),
        enroll_sensitive=can_set_up and panel_input.password_valid and has_selection,
        check_sensitive=idle,
        remove_sensitive=idle,
    )


@dataclass(frozen=True)
class PinForm:
    label: str
    confirm_visible: bool
    hint: str
    error: str
    acceptable: bool


class PinProblem(Enum):
    NONE = "none"
    EMPTY = "empty"
    TOO_SHORT = "too_short"
    MISMATCH = "mismatch"


def _pin_problem(pin, confirm, key_has_pin):
    if not pin:
        return PinProblem.EMPTY
    if key_has_pin:
        return PinProblem.NONE
    if len(pin) < PIN_MIN_LENGTH:
        return PinProblem.TOO_SHORT
    if pin != confirm:
        return PinProblem.MISMATCH
    return PinProblem.NONE


def _pin_error(problem, pin, confirm):
    if not pin and not confirm:
        return ""
    if problem is PinProblem.MISMATCH and not confirm:
        return ""
    texts = {
        PinProblem.NONE: "",
        PinProblem.EMPTY: _(guidance.ERR_PIN_EMPTY),
        PinProblem.TOO_SHORT: _(guidance.ERR_PIN_SHORT).format(n=PIN_MIN_LENGTH),
        PinProblem.MISMATCH: _(guidance.ERR_PIN_MISMATCH),
    }
    return texts[problem]


def pin_form(pin, confirm, key_has_pin):
    problem = _pin_problem(pin, confirm, key_has_pin)
    error = _pin_error(problem, pin, confirm)
    acceptable = problem is PinProblem.NONE
    if key_has_pin:
        return PinForm(_(guidance.KEY_PIN_LABEL), False, "", error, acceptable)
    hint = _(guidance.KEY_NEW_PIN_HINT).format(n=PIN_MIN_LENGTH)
    return PinForm(_(guidance.KEY_NEW_PIN_LABEL), True, hint, error, acceptable)

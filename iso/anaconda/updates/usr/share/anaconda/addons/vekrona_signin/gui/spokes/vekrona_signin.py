from dasbus.error import DBusError

from pyanaconda.anaconda_loggers import get_module_logger
from pyanaconda.core.i18n import N_, _
from pyanaconda.modules.common.constants.services import USERS
from pyanaconda.modules.common.structures.user import UserData
from pyanaconda.modules.common.task import async_run_task
from pyanaconda.ui.communication import hubQ
from pyanaconda.ui.gui.spokes import NormalSpoke

from vekrona_account.categories.vekrona import VekronaCategory
from vekrona_signin.constants import VEKRONA_SIGNIN
from vekrona_signin.core.device_description import DeviceDescription

log = get_module_logger(__name__)

__all__ = ["VekronaSignInSpoke"]

PIN_MIN_LEN = 4
DEFAULT_FINGER = "right-index-finger"
HANDS = (("right", N_("Right")), ("left", N_("Left")))
FINGERS = (
    ("thumb", N_("thumb")),
    ("index", N_("index finger")),
    ("middle", N_("middle finger")),
    ("ring", N_("ring finger")),
    ("little", N_("little finger")),
)


def _finger_choices():
    choices = []
    for hand, hand_name in HANDS:
        for finger, finger_name in FINGERS:
            nick = f"{hand}-{finger}-finger" if finger != "thumb" else f"{hand}-thumb"
            choices.append((nick, _("{} {}").format(_(hand_name), _(finger_name))))
    return choices


class VekronaSignInSpoke(NormalSpoke):
    """The optional sign-in methods spoke: registers a security key and a
    fingerprint through the vekrona_signin service, which owns every device
    operation and every secret."""

    builderObjects = ["VekronaSignInWindow"]
    mainWidgetName = "VekronaSignInWindow"
    uiFile = "vekrona_signin.glade"
    translationDomain = "vekrona-signin-anaconda-addon"

    icon = "dialog-password-symbolic"
    title = N_("_SIGN-IN METHODS")
    category = VekronaCategory

    @staticmethod
    def get_screen_id():
        return "vekrona-signin-configuration"

    @classmethod
    def should_run(cls, environment, data):
        return True

    def __init__(self, *args):
        NormalSpoke.__init__(self, *args)
        self._users_proxy = USERS.get_proxy()
        self._signin_proxy = VEKRONA_SIGNIN.get_proxy()
        self._ready = False
        self._busy = False
        self._has_user = False
        self._key_has_pin = True
        self._key_count = 0
        self._reader_count = 0

    def initialize(self):
        NormalSpoke.initialize(self)
        self.initialize_start()

        get = self.builder.get_object
        self._disabled_label = get("disabledLabel")
        self._content = get("contentBox")

        self._key_combo = get("keyCombo")
        self._key_refresh = get("keyRefreshButton")
        self._key_setup = get("keySetupBox")
        self._key_pin_hint = get("keyPinHint")
        self._key_pin_label = get("keyPinLabel")
        self._key_pin_entry = get("keyPinEntry")
        self._key_confirm_label = get("keyConfirmLabel")
        self._key_confirm_entry = get("keyConfirmEntry")
        self._key_register = get("keyRegisterButton")
        self._key_registered = get("keyRegisteredBox")
        self._key_remove = get("keyRemoveButton")
        self._key_status = get("keyStatus")
        self._key_error = get("keyError")

        self._reader_combo = get("readerCombo")
        self._reader_refresh = get("readerRefreshButton")
        self._finger_combo = get("fingerCombo")
        self._fp_setup = get("fpSetupBox")
        self._fp_enroll = get("fpEnrollButton")
        self._fp_enrolled = get("fpEnrolledBox")
        self._fp_remove = get("fpRemoveButton")
        self._fp_status = get("fpStatus")
        self._fp_error = get("fpError")

        for nick, name in _finger_choices():
            self._finger_combo.append(nick, name)
        self._finger_combo.set_active_id(DEFAULT_FINGER)

        self._key_combo.connect("changed", self.on_key_changed)
        self._key_refresh.connect("clicked", self.on_key_refresh_clicked)
        self._key_pin_entry.connect("changed", self.on_pin_changed)
        self._key_confirm_entry.connect("changed", self.on_pin_changed)
        self._key_register.connect("clicked", self.on_key_register_clicked)
        self._key_remove.connect("clicked", self.on_key_remove_clicked)
        self._reader_combo.connect("changed", self.on_reader_changed)
        self._reader_refresh.connect("clicked", self.on_reader_refresh_clicked)
        self._fp_enroll.connect("clicked", self.on_enroll_clicked)
        self._fp_remove.connect("clicked", self.on_fp_remove_clicked)

        self.initialize_done()
        self._ready = True
        hubQ.send_ready(self.__class__.__name__)

    @property
    def ready(self):
        return self._ready

    @property
    def mandatory(self):
        return False

    @property
    def completed(self):
        return True

    @property
    def status(self):
        try:
            key = self._signin_proxy.SecurityKeyRegistered
            finger = self._signin_proxy.FingerprintEnrolled
        except DBusError as error:
            log.error("vekrona sign-in status unavailable: %s", error)
            return _("unavailable")
        methods = [name for enabled, name in ((key, _("security key")), (finger, _("fingerprint"))) if enabled]
        if not methods:
            return _("Password only")
        return _("Password + {}").format(_(" + ").join(methods))

    def apply(self):
        pass

    def refresh(self):
        self._has_user = self._current_user() is not None
        self._disabled_label.set_visible(not self._has_user)
        self._content.set_visible(self._has_user)
        if self._has_user and not self._busy:
            self._reload_keys()
            self._reload_readers()
        self._update_controls()

    def _current_user(self):
        users = UserData.from_structure_list(self._users_proxy.Users)
        return users[0] if users else None

    def _reload_keys(self):
        devices = self._list_devices(self._key_error, self._signin_proxy.ListSecurityKeys)
        self._key_count = len(devices)
        self._fill_combo(self._key_combo, devices)

    def _reload_readers(self):
        devices = self._list_devices(self._fp_error, self._signin_proxy.ListFingerprintReaders)
        self._reader_count = len(devices)
        self._fill_combo(self._reader_combo, devices)

    def _list_devices(self, error_label, method):
        structures = self._call(error_label, method) or []
        return DeviceDescription.from_structure_list(structures)

    @staticmethod
    def _fill_combo(combo, devices):
        combo.remove_all()
        for device in devices:
            combo.append(device.id, device.name)
        if devices:
            combo.set_active(0)

    def _call(self, error_label, method, *args):
        try:
            result = method(*args)
        except DBusError as error:
            self._show_error(error_label, str(error))
            return None
        self._clear_error(error_label)
        return result

    def _show_error(self, error_label, message):
        log.error("vekrona sign-in: %s", message)
        error_label.set_text(message)
        error_label.set_visible(True)
        self.show_warning_message(message)

    def _clear_error(self, error_label):
        error_label.set_visible(False)
        self.clear_info()

    def _refresh_key_pin_mode(self):
        device_id = self._key_combo.get_active_id()
        if device_id is None:
            self._key_has_pin = True
        else:
            has_pin = self._call(self._key_error, self._signin_proxy.SecurityKeyHasPin, device_id)
            self._key_has_pin = True if has_pin is None else has_pin
        self._key_pin_entry.set_text("")
        self._key_confirm_entry.set_text("")

    def _validate_pin(self):
        pin = self._key_pin_entry.get_text()
        if not self._key_has_pin:
            if len(pin) < PIN_MIN_LEN:
                return _("The PIN must be at least {} characters long.").format(PIN_MIN_LEN)
            if pin != self._key_confirm_entry.get_text():
                return _("The PINs do not match.")
        elif not pin:
            return _("Enter the PIN of the security key.")
        return None

    def _update_controls(self):
        try:
            key_registered = self._signin_proxy.SecurityKeyRegistered
            finger_enrolled = self._signin_proxy.FingerprintEnrolled
        except DBusError as error:
            self._show_error(self._key_error, str(error))
            key_registered = finger_enrolled = False
        idle = self._has_user and not self._busy

        self._key_setup.set_visible(not key_registered)
        self._key_registered.set_visible(key_registered)
        self._key_status.set_text(_("Registered ✓") if key_registered else self._key_empty_text())
        self._key_combo.set_sensitive(idle and self._key_count > 0)
        self._key_refresh.set_sensitive(idle)
        self._key_pin_entry.set_sensitive(idle and self._key_count > 0)
        self._key_confirm_entry.set_sensitive(idle and self._key_count > 0)
        self._key_remove.set_sensitive(idle)
        self._key_pin_hint.set_visible(not self._key_has_pin)
        self._key_pin_label.set_text(_("New PIN") if not self._key_has_pin else _("PIN"))
        self._key_confirm_label.set_visible(not self._key_has_pin)
        self._key_confirm_entry.set_visible(not self._key_has_pin)
        self._key_register.set_sensitive(idle and self._key_count > 0 and self._validate_pin() is None)

        self._fp_setup.set_visible(not finger_enrolled)
        self._fp_enrolled.set_visible(finger_enrolled)
        self._fp_status.set_text(_("Enrolled ✓") if finger_enrolled else self._reader_empty_text())
        self._reader_combo.set_sensitive(idle and self._reader_count > 0)
        self._reader_refresh.set_sensitive(idle)
        self._finger_combo.set_sensitive(idle and self._reader_count > 0)
        self._fp_enroll.set_sensitive(idle and self._reader_count > 0)
        self._fp_remove.set_sensitive(idle)

        hubQ.send_ready(self.__class__.__name__)

    def _key_empty_text(self):
        if self._key_count == 0:
            return _("No security key detected — plug one in and press Refresh")
        return ""

    def _reader_empty_text(self):
        if self._reader_count == 0:
            return _("No fingerprint reader detected — plug one in and press Refresh")
        return ""

    def on_key_changed(self, _combo):
        self._refresh_key_pin_mode()
        self._update_controls()

    def on_reader_changed(self, _combo):
        self._update_controls()

    def on_pin_changed(self, _entry):
        message = self._validate_pin() if self._key_pin_entry.get_text() or self._key_confirm_entry.get_text() else None
        if message:
            self._key_error.set_text(message)
            self._key_error.set_visible(True)
        else:
            self._key_error.set_visible(False)
        self._update_controls()

    def on_key_refresh_clicked(self, _button):
        self._reload_keys()
        self._update_controls()

    def on_reader_refresh_clicked(self, _button):
        self._reload_readers()
        self._update_controls()

    def on_key_register_clicked(self, _button):
        device_id = self._key_combo.get_active_id()
        pin = self._key_pin_entry.get_text()
        set_pin = not self._key_has_pin
        path = self._call(
            self._key_error, self._signin_proxy.RegisterSecurityKeyWithTask, device_id, pin, set_pin
        )
        self._key_pin_entry.set_text("")
        self._key_confirm_entry.set_text("")
        if path is not None:
            self._run_task(path, self._key_status, self._key_error)

    def on_enroll_clicked(self, _button):
        path = self._call(
            self._fp_error,
            self._signin_proxy.EnrollFingerWithTask,
            self._reader_combo.get_active_id(),
            self._finger_combo.get_active_id(),
        )
        if path is not None:
            self._run_task(path, self._fp_status, self._fp_error)

    def on_key_remove_clicked(self, _button):
        self._forget(self._signin_proxy.ForgetSecurityKey, self._key_error)

    def on_fp_remove_clicked(self, _button):
        self._forget(self._signin_proxy.ForgetFingerprint, self._fp_error)

    def _forget(self, method, error_label):
        self._call(error_label, method)
        self._update_controls()

    def _run_task(self, path, status_label, error_label):
        task_proxy = VEKRONA_SIGNIN.get_proxy(path)
        self._busy = True
        self._clear_error(error_label)
        task_proxy.ProgressChanged.connect(lambda _step, message: status_label.set_text(message))

        def on_finished(proxy):
            self._busy = False
            try:
                proxy.Finish()
            except DBusError as error:
                self._show_error(error_label, str(error))
            self._update_controls()

        self._update_controls()
        async_run_task(task_proxy, on_finished)

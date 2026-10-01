import hmac

from dasbus.client.proxy import get_object_path
from dasbus.error import DBusError

from pyanaconda.anaconda_loggers import get_module_logger
from pyanaconda.core.constants import (
    PASSWORD_POLICY_LUKS,
    THREAD_EXECUTE_STORAGE,
    THREAD_STORAGE,
    THREAD_STORAGE_WATCHER,
)
from pyanaconda.core.i18n import N_, _
from pyanaconda.core.threads import thread_manager
from pyanaconda.input_checking import get_policy
from pyanaconda.modules.common.constants.objects import DEVICE_TREE, DISK_INITIALIZATION, DISK_SELECTION
from pyanaconda.modules.common.constants.services import STORAGE, USERS
from pyanaconda.modules.common.task import async_run_task
from pyanaconda.ui.communication import hubQ
from pyanaconda.ui.gui.spokes import NormalSpoke
from pyanaconda.ui.gui.utils import gtk_call_once
from pyanaconda.ui.helpers import StorageCheckHandler
from pyanaconda.ui.lib.storage import apply_partitioning, create_partitioning, reset_storage

from vekrona_account.categories.vekrona import VekronaCategory
from vekrona_account.wheel_user import (
    WheelUserMissing,
    read_wheel_user,
    wheel_password_matches,
    write_wheel_password,
)
from vekrona_signin.constants import VEKRONA_SIGNIN
from vekrona_signin.core.device_scan import DeviceScan
from vekrona_signin.core.diagnose import describe_exception
from vekrona_signin.core.encrypted_storage import apply_encrypted, read_state
from vekrona_signin.core.password_policy import PasswordState, minimum_length, validate
from vekrona_signin.gui.panel_view import FINGERPRINT_PANEL, KEY_PANEL, PanelInput, panel_view, pin_form
from vekrona_signin.gui.signin_state import (
    EncryptionGuard,
    HubSignal,
    HubView,
    Snapshot,
    StorageReaction,
    hub_signal,
    hub_status,
    leave_blocker,
    password_feedback,
    screen_notice,
)
from vekrona_signin.gui.spokes import guidance
from vekrona_signin.gui.spokes.devwatch import DeviceWatcher
from vekrona_signin.gui.storage_link import STORAGE_SPOKE_NAME, find_storage_spoke, seed_storage_spoke

log = get_module_logger(__name__)

__all__ = ["VekronaSignInSpoke"]

ENCRYPT_THREAD_PREFIX = "VekronaEncryptStorage"
STOCK_STORAGE_THREADS = (THREAD_STORAGE, THREAD_STORAGE_WATCHER, THREAD_EXECUTE_STORAGE)


def wait_for_stock_storage():
    for thread_name in STOCK_STORAGE_THREADS:
        thread_manager.wait(thread_name)


class _Panel:
    def __init__(self, kind, *, state_label, combo, check_button, registered_box, remove_button,
                 progress, error_label, details, details_label):
        self.kind = kind
        self.state_label = state_label
        self.combo = combo
        self.check_button = check_button
        self.registered_box = registered_box
        self.remove_button = remove_button
        self.progress = progress
        self.error_label = error_label
        self.details = details
        self.details_label = details_label
        self.scan = None
        self.scan_error = ""
        self.scan_generation = 0
        self.devices = ()
        self.failure = ""


class VekronaSignInSpoke(NormalSpoke):
    builderObjects = ["VekronaSignInWindow"]
    mainWidgetName = "VekronaSignInWindow"
    uiFile = "vekrona_signin.glade"
    translationDomain = "vekrona-signin-anaconda-addon"

    icon = "dialog-password-symbolic"
    title = N_("_VEKRONA SIGN-IN")
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
        self._storage_proxy = STORAGE.get_proxy()
        self._device_tree_proxy = STORAGE.get_proxy(DEVICE_TREE)
        self._disk_selection_proxy = STORAGE.get_proxy(DISK_SELECTION)
        self._disk_initialization_proxy = STORAGE.get_proxy(DISK_INITIALIZATION)
        self._signin_proxy = VEKRONA_SIGNIN.get_proxy()
        self._guard = EncryptionGuard()
        self._snapshot = Snapshot()
        self._watcher = DeviceWatcher(self._on_devices_changed)
        self._shown = None
        self._initialized = False
        self._task_running = False
        self._filling_combo = False
        self._user_changed = False
        self._key_has_pin = True
        self._key_pin_device = None
        self._min_length = 0

    def initialize(self):
        NormalSpoke.initialize(self)
        self.initialize_start()

        self._disabled_label = self.builder.get_object("disabledLabel")
        self._content = self.builder.get_object("contentBox")
        self._notice = self.builder.get_object("noticeLabel")
        self._password_entry = self.builder.get_object("passwordEntry")
        self._confirm_entry = self.builder.get_object("confirmEntry")
        self._password_error = self.builder.get_object("passwordError")
        self._key_setup = self.builder.get_object("keySetupBox")
        self._key_pin_label = self.builder.get_object("keyPinLabel")
        self._key_pin_entry = self.builder.get_object("keyPinEntry")
        self._key_confirm_label = self.builder.get_object("keyConfirmLabel")
        self._key_confirm_entry = self.builder.get_object("keyConfirmEntry")
        self._key_pin_hint = self.builder.get_object("keyPinHint")
        self._key_register = self.builder.get_object("keyRegisterButton")
        self._finger_combo = self.builder.get_object("fingerCombo")
        self._fp_enroll = self.builder.get_object("fpEnrollButton")
        self._key = _Panel(
            KEY_PANEL,
            state_label=self.builder.get_object("keyStateLabel"),
            combo=self.builder.get_object("keyCombo"),
            check_button=self.builder.get_object("keyCheckButton"),
            registered_box=self.builder.get_object("keyRegisteredBox"),
            remove_button=self.builder.get_object("keyRemoveButton"),
            progress=self.builder.get_object("keyProgress"),
            error_label=self.builder.get_object("keyError"),
            details=self.builder.get_object("keyDetails"),
            details_label=self.builder.get_object("keyDetailsLabel"),
        )
        self._fp = _Panel(
            FINGERPRINT_PANEL,
            state_label=self.builder.get_object("fpStateLabel"),
            combo=self.builder.get_object("readerCombo"),
            check_button=self.builder.get_object("fpCheckButton"),
            registered_box=self.builder.get_object("fpRegisteredBox"),
            remove_button=self.builder.get_object("fpRemoveButton"),
            progress=self.builder.get_object("fpProgress"),
            error_label=self.builder.get_object("fpError"),
            details=self.builder.get_object("fpDetails"),
            details_label=self.builder.get_object("fpDetailsLabel"),
        )

        self._min_length = minimum_length(get_policy(PASSWORD_POLICY_LUKS).min_length)
        self._set_static_texts()
        for nick, name in guidance.finger_choices():
            self._finger_combo.append(nick, name)
        self._finger_combo.set_active_id(guidance.DEFAULT_FINGER)

        self.entered.connect(self._on_entered)
        self.exited.connect(self._on_exited)
        self._storage_proxy.PropertiesChanged.connect(self._on_storage_properties_changed)
        self._disk_selection_proxy.PropertiesChanged.connect(self._on_disk_selection_changed)
        self._users_proxy.PropertiesChanged.connect(self._on_users_changed)

        self._snapshot = self._read_snapshot()
        self._initialized = True
        self._shown = self._hub_view()
        self.initialize_done()

    def _set_static_texts(self):
        texts = {
            self.builder.get_object("introLabel"): guidance.INTRO,
            self.builder.get_object("passwordLabel"): guidance.PASSWORD_LABEL,
            self.builder.get_object("confirmLabel"): guidance.CONFIRM_LABEL,
            self.builder.get_object("keyWhatLabel"): guidance.KEY_WHAT,
            self.builder.get_object("keyUseLabel"): guidance.KEY_USE,
            self.builder.get_object("keyStepsLabel"): guidance.KEY_STEPS,
            self.builder.get_object("fpWhatLabel"): guidance.FP_WHAT,
            self.builder.get_object("fpUseLabel"): guidance.FP_USE,
            self.builder.get_object("fpStepsLabel"): guidance.FP_STEPS,
            self.builder.get_object("passwordFrame").get_label_widget(): guidance.PASSWORD_LABEL,
            self.builder.get_object("keyFrame").get_label_widget(): guidance.KEY_TITLE,
            self.builder.get_object("fpFrame").get_label_widget(): guidance.FP_TITLE,
        }
        for label, text in texts.items():
            label.set_text(_(text))
        self.builder.get_object("passwordHint").set_text(
            _(guidance.PASSWORD_HINT).format(n=self._min_length)
        )
        for panel in (self._key, self._fp):
            panel.details.set_label(_(guidance.DETAILS_TITLE))

    @property
    def ready(self):
        return self._initialized and not self._guard.applying and not self._task_running

    @property
    def mandatory(self):
        return True

    @property
    def sensitive(self):
        try:
            return read_wheel_user(self._users_proxy) is not None
        except DBusError as error:
            log.error("Reading the account failed: %s", error)
            return False

    @property
    def completed(self):
        return self._snapshot.completed

    @property
    def status(self):
        return hub_status(self._snapshot, self._guard)

    def _hub_view(self):
        return HubView(ready=self.ready, completed=self.completed, status=self.status)

    def _notify_hub(self):
        current = self._hub_view()
        signal = hub_signal(self._shown, current)
        self._shown = current
        if signal is HubSignal.READY:
            hubQ.send_ready(self.__class__.__name__)
        elif signal is HubSignal.NOT_READY:
            hubQ.send_not_ready(self.__class__.__name__)
        elif signal is HubSignal.MESSAGE:
            hubQ.send_message(self.__class__.__name__, current.status)

    def _passphrase_matches(self, passphrase):
        if self._guard.password is not None:
            return hmac.compare_digest(passphrase.encode(), self._guard.password.encode())
        return wheel_password_matches(self._users_proxy, passphrase)

    def _read_snapshot(self):
        try:
            user = read_wheel_user(self._users_proxy)
            if user is None:
                return Snapshot()
            storage_state = read_state(
                self._passphrase_matches,
                wait_until_idle=wait_for_stock_storage,
                storage=self._storage_proxy,
                get_partitioning_proxy=STORAGE.get_proxy,
                device_tree=self._device_tree_proxy,
                disk_selection=self._disk_selection_proxy,
            )
            return Snapshot(
                username=user.name,
                has_password=bool(user.password),
                storage_state=storage_state,
                applied_path=self._storage_proxy.AppliedPartitioning,
                key_registered=self._signin_proxy.SecurityKeyRegistered,
                finger_enrolled=self._signin_proxy.FingerprintEnrolled,
            )
        except DBusError as error:
            log.error("Reading the account and disk state failed: %s", error)
            return Snapshot(error=str(error))

    def _forget_registrations_of_other_user(self):
        if not self._snapshot.has_account:
            return
        try:
            forgotten = self._signin_proxy.ForgetIfUserChanged(self._snapshot.username)
        except DBusError as error:
            log.error("Checking the registrations against the username failed: %s", error)
            self._key.failure = self._fp.failure = str(error)
            return
        if forgotten:
            log.info("The username changed; the registered sign-in methods were forgotten.")
            self._user_changed = True
            self._snapshot = self._read_snapshot()

    def _on_storage_properties_changed(self, _interface, changed, _invalidated):
        if "AppliedPartitioning" not in changed:
            return
        self._snapshot = self._read_snapshot()
        reaction = self._guard.react_to_storage_change(self._snapshot)
        log.info("The applied disk setup changed: %s; %s.", self._snapshot.storage_state.value, reaction.value)
        if reaction is StorageReaction.RECONCILE:
            self._start_encryption()
        elif reaction is StorageReaction.REEVALUATE:
            self._notify_hub()

    def _on_disk_selection_changed(self, _interface, changed, _invalidated):
        if "SelectedDisks" not in changed:
            return
        self._snapshot = self._read_snapshot()
        self._notify_hub()

    def _on_users_changed(self, _interface, changed, _invalidated):
        if "Users" not in changed:
            return
        self._snapshot = self._read_snapshot()
        self._forget_registrations_of_other_user()
        self._notify_hub()

    def refresh(self):
        self._snapshot = self._read_snapshot()
        self._forget_registrations_of_other_user()
        has_account = self._snapshot.has_account
        self._disabled_label.set_text(
            screen_notice(self._snapshot, self._guard) or hub_status(self._snapshot, self._guard)
        )
        self._disabled_label.set_visible(not has_account)
        self._content.set_visible(has_account)
        if self._guard.password is not None:
            self._password_entry.set_text(self._guard.password)
            self._confirm_entry.set_text(self._guard.password)
        self._update_password_feedback()
        if has_account:
            self._scan(self._key)
            self._scan(self._fp)
        self._render()

    def _on_entered(self, _spoke):
        self._watcher.start()
        self._render()

    def _on_exited(self, _spoke):
        self._watcher.stop()
        self._user_changed = False

    def _on_devices_changed(self):
        self._scan(self._key)
        self._scan(self._fp)

    def _password_state(self):
        return validate(self._password_entry.get_text(), self._confirm_entry.get_text(), self._min_length)

    def _update_password_feedback(self):
        message = password_feedback(self._password_state(), self._confirm_entry.get_text(), self._min_length)
        self._show_message(self._password_error, message)

    def apply(self):
        if self._password_state() is PasswordState.VALID and not self._accept_password(
            self._password_entry.get_text()
        ):
            self._notify_hub()
            return
        self._snapshot = self._read_snapshot()
        if self._guard.should_encrypt(self._snapshot.storage_state):
            self._start_encryption()
        else:
            self._notify_hub()

    def _accept_password(self, password):
        if password != self._guard.password:
            try:
                write_wheel_password(self._users_proxy, password)
            except (DBusError, WheelUserMissing) as error:
                log.error("Writing the account password failed: %s", error)
                self._guard.account_error = str(error)
                return False
            self._guard.account_error = ""
            self._guard.accept_password(password)
            log.info("The account password was set; it is also the disk passphrase.")
        self._seed_storage_spoke()
        return True

    def _seed_storage_spoke(self):
        storage_spoke = find_storage_spoke(self)
        if storage_spoke is not None:
            seed_storage_spoke(storage_spoke, self._guard.password)
        return storage_spoke

    def _start_encryption(self):
        log.info("Encrypting the disk setup with the account password; it was %s.",
                 self._snapshot.storage_state.value)
        self._guard.begin()
        self._render()
        self._notify_hub()
        thread_manager.add_thread(
            prefix=ENCRYPT_THREAD_PREFIX,
            target=self._encrypt_storage,
            args=(self._guard.password,),
        )

    def _encrypt_storage(self, password):
        try:
            wait_for_stock_storage()
            report, partitioning = apply_encrypted(
                password,
                show_message=lambda message: hubQ.send_message(self.__class__.__name__, message),
                reset_storage_cb=lambda: reset_storage(scan_all=True),
                storage=self._storage_proxy,
                get_partitioning_proxy=STORAGE.get_proxy,
                disk_selection=self._disk_selection_proxy,
                disk_initialization=self._disk_initialization_proxy,
                create_partitioning=create_partitioning,
                apply=apply_partitioning,
            )
        except Exception as error:
            log.error("Encrypting the disk setup failed: %s", describe_exception(error))
            gtk_call_once(self._on_encryption_done, describe_exception(error), [], "")
            return
        applied_by_us = get_object_path(partitioning) if report.is_valid() else ""
        gtk_call_once(
            self._on_encryption_done, " ".join(report.error_messages), list(report.warning_messages), applied_by_us
        )

    def _on_encryption_done(self, error, warnings, applied_by_us):
        self._snapshot = self._read_snapshot()
        reaction = self._guard.finish(self._snapshot, error, applied_by_us)
        if reaction is StorageReaction.ENCRYPTED:
            log.info("The disk setup is encrypted with the account password.")
            StorageCheckHandler.errors = []
            StorageCheckHandler.warnings = warnings
            storage_spoke = self._seed_storage_spoke()
            if storage_spoke is not None and storage_spoke.ready:
                hubQ.send_ready(STORAGE_SPOKE_NAME)
        elif self._guard.failure:
            log.error("The disk setup is not encrypted with the account password: %s", self._guard.failure)
        else:
            log.info("Another disk setup was applied after ours: %s.", self._snapshot.storage_state.value)
        if reaction is StorageReaction.RECONCILE:
            self._start_encryption()
            return
        self._render()
        self._notify_hub()

    def on_back_clicked(self, button):
        blocker = leave_blocker(
            self._password_state(), self._password_entry.get_text(), self._confirm_entry.get_text(), self._min_length
        )
        if blocker:
            self.show_warning_message(blocker)
            return
        self.clear_info()
        NormalSpoke.on_back_clicked(self, button)

    def on_password_changed(self, _entry):
        self._update_password_feedback()
        self._render()

    def _scan(self, panel):
        panel.scan_generation += 1
        scan = self._signin_proxy.ScanSecurityKeys if panel is self._key else self._signin_proxy.ScanFingerprintReaders
        scan(callback=self._on_scan_finished, callback_args=(panel, panel.scan_generation))

    def _on_scan_finished(self, get_result, panel, generation):
        if generation != panel.scan_generation:
            return
        try:
            panel.scan = DeviceScan.from_structure(get_result())
            panel.scan_error = ""
        except Exception as error:
            log.error("Looking for devices failed: %s", describe_exception(error))
            panel.scan_error = describe_exception(error)
        else:
            if panel.scan.problem:
                log.warning("Device scan problem: %s [%s]", panel.scan.problem, panel.scan.hint_code)
        self._render_panel(panel)
        if panel is self._key:
            self._refresh_key_pin_mode()

    def _render(self):
        notice = screen_notice(self._snapshot, self._guard) if self._snapshot.has_account else ""
        self._show_message(self._notice, notice)
        self._render_panel(self._key)
        self._render_panel(self._fp)
        self._update_sensitivity()

    def _panel_input(self, panel):
        registered = self._snapshot.key_registered if panel is self._key else self._snapshot.finger_enrolled
        return PanelInput(
            scan=panel.scan,
            scan_error=panel.scan_error,
            selected_id=panel.combo.get_active_id(),
            registered=registered,
            password_valid=self._password_state() is PasswordState.VALID,
            busy=self._task_running or self._guard.applying,
            watch_available=self._watcher.available,
            user_changed=self._user_changed,
        )

    def _render_panel(self, panel):
        view = panel_view(panel.kind, self._panel_input(panel))
        if view.devices != panel.devices:
            self._fill_combo(panel, view.devices)
            view = panel_view(panel.kind, self._panel_input(panel))
        panel.state_label.set_text(view.state_text)
        panel.details_label.set_text(view.details_text)
        panel.registered_box.set_visible(view.show_registered)
        panel.combo.set_sensitive(view.choose_sensitive)
        panel.check_button.set_sensitive(view.check_sensitive)
        panel.remove_button.set_sensitive(view.remove_sensitive)
        if panel is self._key:
            self._render_key_setup(view)
        else:
            self._render_fingerprint_setup(view)

    def _fill_combo(self, panel, devices):
        previous = panel.combo.get_active_id()
        panel.devices = devices
        self._filling_combo = True
        try:
            panel.combo.remove_all()
            for device_id, name in devices:
                panel.combo.append(device_id, name)
            if devices and (previous is None or not panel.combo.set_active_id(previous)):
                panel.combo.set_active(0)
        finally:
            self._filling_combo = False

    def _render_key_setup(self, view):
        form = pin_form(self._key_pin_entry.get_text(), self._key_confirm_entry.get_text(), self._key_has_pin)
        self._key_setup.set_visible(view.show_setup)
        self._key_pin_label.set_text(form.label)
        self._key_confirm_label.set_visible(form.confirm_visible)
        self._key_confirm_entry.set_visible(form.confirm_visible)
        self._key_pin_hint.set_text(form.hint)
        self._key_pin_hint.set_visible(bool(form.hint))
        self._key_pin_entry.set_sensitive(view.enroll_sensitive)
        self._key_confirm_entry.set_sensitive(view.enroll_sensitive)
        self._key_register.set_sensitive(view.enroll_sensitive and form.acceptable)
        self._show_message(self._key.error_label, self._key.failure or form.error)

    def _render_fingerprint_setup(self, view):
        self._finger_combo.set_visible(view.show_setup)
        self._fp_enroll.set_visible(view.show_setup)
        self._finger_combo.set_sensitive(view.enroll_sensitive)
        self._fp_enroll.set_sensitive(view.enroll_sensitive)
        self._show_message(self._fp.error_label, self._fp.failure)

    def _update_sensitivity(self):
        idle = not self._task_running and not self._guard.applying
        self._password_entry.set_sensitive(idle)
        self._confirm_entry.set_sensitive(idle)

    def _refresh_key_pin_mode(self):
        device_id = self._key.combo.get_active_id()
        if device_id == self._key_pin_device:
            return
        self._key_pin_device = device_id
        self._key_has_pin = True
        self._key.failure = ""
        self._key_pin_entry.set_text("")
        self._key_confirm_entry.set_text("")
        if device_id is not None:
            self._signin_proxy.SecurityKeyHasPin(
                device_id, callback=self._on_key_pin_mode, callback_args=(device_id,)
            )

    def _on_key_pin_mode(self, get_result, device_id):
        if device_id != self._key_pin_device:
            return
        try:
            self._key_has_pin = get_result()
        except DBusError as error:
            log.error("vekrona sign-in: %s", error)
            self._key.failure = str(error)
        self._render_panel(self._key)

    @staticmethod
    def _call(panel, method, *args):
        try:
            return method(*args)
        except DBusError as error:
            log.error("vekrona sign-in: %s", error)
            panel.failure = str(error)
            return None

    @staticmethod
    def _show_message(label, message):
        label.set_text(message)
        label.set_visible(bool(message))

    def on_key_combo_changed(self, _combo):
        if self._filling_combo:
            return
        self._refresh_key_pin_mode()
        self._render_panel(self._key)

    def on_reader_combo_changed(self, _combo):
        if self._filling_combo:
            return
        self._render_panel(self._fp)

    def on_key_pin_changed(self, _entry):
        self._render_panel(self._key)

    def on_key_check_clicked(self, _button):
        self._key.failure = ""
        self._scan(self._key)

    def on_fp_check_clicked(self, _button):
        self._fp.failure = ""
        self._scan(self._fp)

    def on_key_register_clicked(self, _button):
        device_id = self._key.combo.get_active_id()
        pin = self._key_pin_entry.get_text()
        set_pin = not self._key_has_pin
        self._key_pin_entry.set_text("")
        self._key_confirm_entry.set_text("")
        path = self._call(self._key, self._signin_proxy.RegisterSecurityKeyWithTask, device_id, pin, set_pin)
        if path is None:
            self._render_panel(self._key)
            return
        self._run_task(path, self._key)

    def on_fp_enroll_clicked(self, _button):
        path = self._call(
            self._fp,
            self._signin_proxy.EnrollFingerWithTask,
            self._fp.combo.get_active_id(),
            self._finger_combo.get_active_id(),
        )
        if path is None:
            self._render_panel(self._fp)
            return
        self._run_task(path, self._fp)

    def on_key_remove_clicked(self, _button):
        self._forget(self._signin_proxy.ForgetSecurityKey, self._key)

    def on_fp_remove_clicked(self, _button):
        self._forget(self._signin_proxy.ForgetFingerprint, self._fp)

    def _forget(self, method, panel):
        panel.failure = ""
        self._call(panel, method)
        self._snapshot = self._read_snapshot()
        self._render()
        self._notify_hub()

    def _run_task(self, path, panel):
        task_proxy = VEKRONA_SIGNIN.get_proxy(path)
        steps = self._call(panel, lambda: task_proxy.Steps)
        if steps is None:
            self._render_panel(panel)
            return

        def on_progress(step, message):
            panel.progress.set_text(message)
            if steps > 1:
                panel.progress.set_fraction(min(1.0, (step + 1) / steps))
            else:
                panel.progress.pulse()

        def on_finished(proxy):
            proxy.ProgressChanged.disconnect(on_progress)
            self._call(panel, proxy.Finish)
            self._task_done(panel)

        self._task_running = True
        self._user_changed = False
        panel.failure = ""
        panel.progress.set_fraction(0.0)
        panel.progress.set_text("")
        panel.progress.set_visible(True)
        self._render()
        self._notify_hub()
        task_proxy.ProgressChanged.connect(on_progress)
        try:
            async_run_task(task_proxy, on_finished)
        except DBusError as error:
            task_proxy.ProgressChanged.disconnect(on_progress)
            log.error("vekrona sign-in: %s", error)
            panel.failure = str(error)
            self._task_done(panel)

    def _task_done(self, panel):
        self._task_running = False
        panel.progress.set_visible(False)
        self._snapshot = self._read_snapshot()
        self._render()
        self._notify_hub()

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from pyanaconda.core.i18n import N_, _
from pyanaconda.modules.common.constants.services import NETWORK, TIMEZONE, USERS
from pyanaconda.timezone import all_timezones, is_valid_timezone
from pyanaconda.ui.communication import hubQ
from pyanaconda.ui.gui.spokes import NormalSpoke

from vekrona_account.account_settings import (
    apply_account,
    is_account_complete,
    validate_hostname,
    validate_timezone,
    validate_username,
)
from vekrona_account.categories.vekrona import VekronaCategory
from vekrona_account.constants import DEFAULT_HOSTNAME, DEFAULT_TIMEZONE
from vekrona_account.wheel_user import read_wheel_user

__all__ = ["VekronaAccountSpoke"]


class VekronaAccountSpoke(NormalSpoke):
    builderObjects = ["VekronaAccountWindow"]
    mainWidgetName = "VekronaAccountWindow"
    uiFile = "vekrona_account.glade"
    translationDomain = "vekrona-account-anaconda-addon"

    icon = "avatar-default-symbolic"
    title = N_("_VEKRONA ACCOUNT")
    category = VekronaCategory

    @staticmethod
    def get_screen_id():
        return "vekrona-account-configuration"

    @classmethod
    def should_run(cls, environment, data):
        return True

    def __init__(self, *args):
        NormalSpoke.__init__(self, *args)
        self._users_proxy = USERS.get_proxy()
        self._timezone_proxy = TIMEZONE.get_proxy()
        self._network_proxy = NETWORK.get_proxy()
        self._ready = False

    def initialize(self):
        NormalSpoke.initialize(self)
        self.initialize_start()

        self._full_name_entry = self.builder.get_object("fullNameEntry")
        self._username_entry = self.builder.get_object("usernameEntry")
        self._username_error = self.builder.get_object("usernameError")
        self._hostname_entry = self.builder.get_object("hostnameEntry")
        self._hostname_error = self.builder.get_object("hostnameError")
        self._timezone_entry = self.builder.get_object("timezoneEntry")
        self._timezone_error = self.builder.get_object("timezoneError")

        store = Gtk.ListStore(str)
        for tz in sorted(all_timezones()):
            store.append([tz])
        completion = Gtk.EntryCompletion()
        completion.set_model(store)
        completion.set_text_column(0)
        completion.set_inline_completion(False)
        completion.set_popup_completion(True)
        completion.set_match_func(self._timezone_match_func)
        self._timezone_entry.set_completion(completion)

        for entry in (
            self._full_name_entry, self._username_entry,
            self._hostname_entry, self._timezone_entry,
        ):
            entry.connect("changed", self.on_field_changed)

        self.initialize_done()
        self._ready = True
        hubQ.send_ready(self.__class__.__name__)

    @staticmethod
    def _timezone_match_func(completion, key, tree_iter):
        value = completion.get_model()[tree_iter][0]
        return key.lower() in value.lower()

    def on_field_changed(self, _entry):
        self._validate()

    def refresh(self):
        user = read_wheel_user(self._users_proxy)
        if user is not None:
            self._username_entry.set_text(user.name)
            self._full_name_entry.set_text(user.gecos)
        if not self._hostname_entry.get_text():
            self._hostname_entry.set_text(self._network_proxy.Hostname or DEFAULT_HOSTNAME)
        if not self._timezone_entry.get_text():
            tz = self._timezone_proxy.Timezone
            self._timezone_entry.set_text(tz if is_valid_timezone(tz) else DEFAULT_TIMEZONE)
        self._validate()

    def _validate(self):
        errors = {
            self._username_error: validate_username(self._username_entry.get_text()),
            self._hostname_error: validate_hostname(self._hostname_entry.get_text()),
            self._timezone_error: validate_timezone(self._timezone_entry.get_text()),
        }
        for label, message in errors.items():
            if message:
                label.set_text(message)
                label.set_visible(True)
            else:
                label.set_visible(False)
        hubQ.send_ready(self.__class__.__name__)
        return not any(errors.values())

    @property
    def ready(self):
        return self._ready

    @property
    def completed(self):
        return is_account_complete(self._users_proxy, self._network_proxy, self._timezone_proxy)

    @property
    def status(self):
        user = read_wheel_user(self._users_proxy)
        if user is None:
            return _("not set")
        if not self.completed:
            return _("incomplete")
        return _("{} (admin), {}").format(user.name, self._timezone_proxy.Timezone)

    def on_back_clicked(self, button):
        if not self._validate():
            self.show_warning_message(_("Correct the marked fields before leaving this screen."))
            return
        self.clear_info()
        NormalSpoke.on_back_clicked(self, button)

    def apply(self):
        apply_account(
            self._users_proxy,
            self._network_proxy,
            self._timezone_proxy,
            name=self._username_entry.get_text(),
            gecos=self._full_name_entry.get_text(),
            hostname=self._hostname_entry.get_text(),
            timezone=self._timezone_entry.get_text(),
        )

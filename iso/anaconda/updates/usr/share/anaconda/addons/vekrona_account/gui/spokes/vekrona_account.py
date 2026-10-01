import re

from pykickstart.constants import AUTOPART_TYPE_BTRFS

from pyanaconda.anaconda_loggers import get_module_logger
from pyanaconda.core.constants import PARTITIONING_METHOD_AUTOMATIC, PASSWORD_POLICY_LUKS
from pyanaconda.core.i18n import N_, _
from pyanaconda.core.users import check_username, crypt_password
from pyanaconda.input_checking import get_policy
from pyanaconda.modules.common.constants.services import NETWORK, STORAGE, TIMEZONE, USERS
from pyanaconda.modules.common.structures.partitioning import PartitioningRequest
from pyanaconda.modules.common.structures.user import UserData
from pyanaconda.network import is_valid_hostname
from pyanaconda.ui.communication import hubQ
from pyanaconda.ui.gui.spokes import NormalSpoke
from pyanaconda.ui.lib.storage import create_partitioning
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from vekrona_account.categories.vekrona import VekronaCategory
from vekrona_account.constants import DEFAULT_HOSTNAME, DEFAULT_TIMEZONE

log = get_module_logger(__name__)

__all__ = ["VekronaAccountSpoke"]

USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]*$")
USERNAME_MAX_LEN = 32
PASSPHRASE_MIN_LEN = 8
LUKS_VERSION = "luks2"


class VekronaAccountSpoke(NormalSpoke):
    """The vekrona account spoke: one screen for the admin account, the
    LUKS passphrase (reusing the account password), hostname and timezone."""

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
        self._storage_proxy = STORAGE.get_proxy()
        self._ready = False
        self._valid_timezones = set()
        self._validation_errors = []

    def initialize(self):
        NormalSpoke.initialize(self)
        self.initialize_start()

        self._full_name_entry = self.builder.get_object("fullNameEntry")
        self._username_entry = self.builder.get_object("usernameEntry")
        self._username_error = self.builder.get_object("usernameError")
        self._password_entry = self.builder.get_object("passwordEntry")
        self._confirm_entry = self.builder.get_object("confirmEntry")
        self._password_error = self.builder.get_object("passwordError")
        self._hostname_entry = self.builder.get_object("hostnameEntry")
        self._hostname_error = self.builder.get_object("hostnameError")
        self._timezone_entry = self.builder.get_object("timezoneEntry")
        self._timezone_error = self.builder.get_object("timezoneError")

        tz_dict = self._timezone_proxy.GetAllValidTimezones()
        self._valid_timezones = {DEFAULT_TIMEZONE} | {
            f"{region}/{city}" for region, cities in tz_dict.items() for city in cities
        }
        store = Gtk.ListStore(str)
        for tz in sorted(self._valid_timezones):
            store.append([tz])
        completion = Gtk.EntryCompletion()
        completion.set_model(store)
        completion.set_text_column(0)
        completion.set_inline_completion(False)
        completion.set_popup_completion(True)
        completion.set_match_func(self._timezone_match_func)
        self._timezone_entry.set_completion(completion)

        for entry in (
            self._full_name_entry, self._username_entry, self._password_entry,
            self._confirm_entry, self._hostname_entry, self._timezone_entry,
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
        user = self._current_user()
        if user is not None:
            self._username_entry.set_text(user.name)
            self._full_name_entry.set_text(user.gecos)
        if not self._hostname_entry.get_text():
            self._hostname_entry.set_text(self._network_proxy.Hostname or DEFAULT_HOSTNAME)
        if not self._timezone_entry.get_text():
            tz = self._timezone_proxy.Timezone
            self._timezone_entry.set_text(tz if tz in self._valid_timezones else DEFAULT_TIMEZONE)
        self._validate()

    def _current_user(self):
        for user in UserData.from_structure_list(self._users_proxy.Users):
            if "wheel" in user.groups:
                return user
        return None

    def _validate_username(self):
        name = self._username_entry.get_text()
        if not name:
            return _("A username is required.")
        if len(name) > USERNAME_MAX_LEN:
            return _("Username must be {} characters or fewer.").format(USERNAME_MAX_LEN)
        if not USERNAME_RE.match(name):
            return _("Use lowercase letters, digits, - and _, starting with a letter or _.")
        valid, message = check_username(name)
        if not valid:
            return message
        return None

    def _validate_password(self):
        password = self._password_entry.get_text()
        confirm = self._confirm_entry.get_text()
        if not password:
            return _("A password is required.")
        if password != confirm:
            return _("The passwords do not match.")
        min_length = self._passphrase_min_length()
        if len(password) < min_length:
            return _("The password must be at least {} characters long.").format(min_length)
        return None

    @staticmethod
    def _passphrase_min_length():
        return max(PASSPHRASE_MIN_LEN, get_policy(PASSWORD_POLICY_LUKS).min_length)

    def _validate_hostname(self):
        hostname = self._hostname_entry.get_text()
        if not hostname:
            return _("A hostname is required.")
        valid, message = is_valid_hostname(hostname, local=True)
        if not valid:
            return message
        return None

    def _validate_timezone(self):
        timezone = self._timezone_entry.get_text()
        if not timezone:
            return _("A timezone is required.")
        if timezone not in self._valid_timezones:
            return _("Not a recognized timezone; pick one from the list.")
        return None

    def _validate(self):
        errors = {
            self._username_error: self._validate_username(),
            self._password_error: self._validate_password(),
            self._hostname_error: self._validate_hostname(),
            self._timezone_error: self._validate_timezone(),
        }
        for label, message in errors.items():
            if message:
                label.set_text(message)
                label.set_visible(True)
                label.set_no_show_all(False)
            else:
                label.set_visible(False)
        self._validation_errors = [message for message in errors.values() if message]
        hubQ.send_ready(self.__class__.__name__)
        return not self._validation_errors

    @property
    def ready(self):
        return self._ready

    @property
    def completed(self):
        return self._modules_already_configured()

    def _modules_already_configured(self):
        user = self._current_user()
        if user is None or not user.password or not self._users_proxy.IsRootAccountLocked:
            return False
        if not self._network_proxy.Hostname:
            return False
        if self._timezone_proxy.Timezone not in self._valid_timezones:
            return False
        return self._auto_partitioning_matches_request()

    def _auto_partitioning_matches_request(self):
        paths = self._storage_proxy.CreatedPartitioning
        if not paths:
            return False
        proxy = STORAGE.get_proxy(paths[-1])
        if proxy.PartitioningMethod != PARTITIONING_METHOD_AUTOMATIC:
            return False
        request = PartitioningRequest.from_structure(proxy.Request)
        return (
            request.partitioning_scheme == AUTOPART_TYPE_BTRFS
            and request.encrypted
            and request.luks_version == LUKS_VERSION
            and bool(request.passphrase)
        )

    def _automatic_partitioning(self):
        paths = self._storage_proxy.CreatedPartitioning
        if paths:
            proxy = STORAGE.get_proxy(paths[-1])
            if proxy.PartitioningMethod == PARTITIONING_METHOD_AUTOMATIC:
                return proxy
        return create_partitioning(PARTITIONING_METHOD_AUTOMATIC)

    @property
    def status(self):
        user = self._current_user()
        if user is None:
            return _("not set")
        if not self.completed:
            return _("incomplete: {}").format(
                self._validation_errors[0] if self._validation_errors else _("storage was changed, re-enter the password")
            )
        return _("{} (admin), {}").format(user.name, self._timezone_entry.get_text() or "?")

    def apply(self):
        if not self._validate():
            log.error("vekrona account not applied: %s", "; ".join(self._validation_errors))
            return

        user = UserData()
        user.name = self._username_entry.get_text()
        user.gecos = self._full_name_entry.get_text()
        user.groups = ["wheel"]
        password = self._password_entry.get_text()
        user.password = crypt_password(password)
        user.is_crypted = True
        self._users_proxy.Users = UserData.to_structure_list([user])
        self._users_proxy.IsRootAccountLocked = True

        self._network_proxy.Hostname = self._hostname_entry.get_text()
        self._timezone_proxy.Timezone = self._timezone_entry.get_text()

        partitioning = self._automatic_partitioning()
        request = PartitioningRequest.from_structure(partitioning.Request)
        request.partitioning_scheme = AUTOPART_TYPE_BTRFS
        request.encrypted = True
        request.luks_version = LUKS_VERSION
        request.passphrase = password
        partitioning.Request = PartitioningRequest.to_structure(request)

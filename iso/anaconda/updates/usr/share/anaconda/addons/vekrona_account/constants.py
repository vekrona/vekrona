from dasbus.identifier import DBusServiceIdentifier

from pyanaconda.core.dbus import DBus
from pyanaconda.modules.common.constants.namespaces import ADDONS_NAMESPACE

VEKRONA_ACCOUNT_NAMESPACE = (*ADDONS_NAMESPACE, "VekronaAccount")

VEKRONA_ACCOUNT = DBusServiceIdentifier(
    namespace=VEKRONA_ACCOUNT_NAMESPACE,
    message_bus=DBus
)

DEFAULT_HOSTNAME = "vekrona"
DEFAULT_TIMEZONE = "UTC"

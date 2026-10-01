from dasbus.identifier import DBusServiceIdentifier

from pyanaconda.core.dbus import DBus
from pyanaconda.modules.common.constants.namespaces import ADDONS_NAMESPACE

VEKRONA_SIGNIN_NAMESPACE = (*ADDONS_NAMESPACE, "VekronaSignIn")

VEKRONA_SIGNIN = DBusServiceIdentifier(
    namespace=VEKRONA_SIGNIN_NAMESPACE,
    message_bus=DBus
)

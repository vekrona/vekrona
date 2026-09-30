from dasbus.server.interface import dbus_interface

from pyanaconda.modules.common.base import KickstartModuleInterface
from vekrona_account.constants import VEKRONA_ACCOUNT

__all__ = ["VekronaAccountInterface"]


@dbus_interface(VEKRONA_ACCOUNT.interface_name)
class VekronaAccountInterface(KickstartModuleInterface):
    """The DBus interface of the vekrona account service.

    The account fields live in the Users/Timezone/Network/Storage modules
    (the vekrona spoke writes straight into those), so this interface
    adds nothing to the kickstart module interface.
    """

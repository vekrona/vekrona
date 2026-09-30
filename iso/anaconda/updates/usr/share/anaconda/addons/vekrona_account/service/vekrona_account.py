from pyanaconda.core.dbus import DBus
from pyanaconda.modules.common.base import KickstartService
from pyanaconda.modules.common.containers import TaskContainer

from vekrona_account.constants import VEKRONA_ACCOUNT
from vekrona_account.service.kickstart import VekronaAccountKickstartSpecification
from vekrona_account.service.vekrona_account_interface import VekronaAccountInterface

__all__ = ["VekronaAccountService"]


class VekronaAccountService(KickstartService):
    """The implementation of the vekrona account service."""

    def publish(self):
        TaskContainer.set_namespace(VEKRONA_ACCOUNT.namespace)
        DBus.publish_object(VEKRONA_ACCOUNT.object_path, VekronaAccountInterface(self))
        DBus.register_service(VEKRONA_ACCOUNT.service_name)

    @property
    def kickstart_specification(self):
        return VekronaAccountKickstartSpecification

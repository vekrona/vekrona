from pyanaconda.anaconda_loggers import get_module_logger

from vekrona_signin.core.storage_policy import with_encryption

log = get_module_logger(__name__)

__all__ = ["STORAGE_SPOKE_NAME", "find_storage_spoke", "seed_storage_spoke"]

STORAGE_SPOKE_NAME = "StorageSpoke"
ENCRYPTION_CHECKBOX_ID = "encryptionCheckbox"


def find_storage_spoke(spoke):
    # Anaconda 44.30 internals: spoke.main_window.current_action._spokes maps class names to instances.
    try:
        found = spoke.main_window.current_action._spokes.get(STORAGE_SPOKE_NAME)
    except AttributeError:
        found = None
    if found is None:
        log.warning("The stock Installation Destination spoke was not found; it is not pre-filled.")
    return found


def seed_storage_spoke(storage_spoke, password):
    # Anaconda 44.30 StorageSpoke: _partitioning_request is a snapshot of the request taken at
    # construction and used on Done; builder holds the "encryptionCheckbox".
    request = getattr(storage_spoke, "_partitioning_request", None)
    builder = getattr(storage_spoke, "builder", None)
    checkbox = builder.get_object(ENCRYPTION_CHECKBOX_ID) if builder is not None else None
    if request is None or checkbox is None:
        log.warning("The stock Installation Destination spoke cannot be pre-filled.")
        return False
    storage_spoke._partitioning_request = with_encryption(request, password)
    checkbox.set_active(True)
    return True

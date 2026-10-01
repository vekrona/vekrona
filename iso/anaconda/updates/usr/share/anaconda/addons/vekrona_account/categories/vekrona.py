from pyanaconda.core.i18n import N_
from pyanaconda.ui.categories import SpokeCategory

__all__ = ["VekronaCategory"]


class VekronaCategory(SpokeCategory):
    """The category of the vekrona account and sign-in spokes, sorted right after the stock
    System category so the disk is set up before the sign-in password is applied to it."""

    @staticmethod
    def get_title():
        return N_("VEKRONA")

    @staticmethod
    def get_sort_order():
        return 350

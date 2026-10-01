from pyanaconda.core.i18n import N_
from pyanaconda.ui.categories import SpokeCategory

__all__ = ["VekronaCategory"]


class VekronaCategory(SpokeCategory):
    """The category of the vekrona account and sign-in spokes, sorted before
    every stock category so it is the first thing the user sees on the hub."""

    @staticmethod
    def get_title():
        return N_("VEKRONA")

    @staticmethod
    def get_sort_order():
        return 50

from pyanaconda.core.kickstart import KickstartSpecification

__all__ = ["VekronaAccountKickstartSpecification"]


class VekronaAccountKickstartSpecification(KickstartSpecification):
    """The vekrona account is only ever set from the GUI spoke or the test
    kickstart's own `user`/`autopart` commands; it has nothing of its own
    to parse."""

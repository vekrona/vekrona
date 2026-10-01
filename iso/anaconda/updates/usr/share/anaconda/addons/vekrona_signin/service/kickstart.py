from pyanaconda.core.kickstart import KickstartSpecification

__all__ = ["VekronaSignInKickstartSpecification"]


class VekronaSignInKickstartSpecification(KickstartSpecification):
    """Sign-in methods are only ever registered from the GUI spoke;
    there is nothing for a kickstart file to configure."""

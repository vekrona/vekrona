class SignInError(Exception):
    """A sign-in method could not be set up; the message is shown to the user."""


class PassphraseRejected(SignInError):
    """The LUKS device refused the passphrase."""

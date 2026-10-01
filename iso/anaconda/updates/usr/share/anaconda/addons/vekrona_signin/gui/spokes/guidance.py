from pyanaconda.core.i18n import N_, _

from vekrona_signin.core.device_scan import HintCode
from vekrona_signin.core.password_policy import PasswordState

INTRO = N_("Choose one password. It is the password for your account. When the installer encrypts the disk for you, it unlocks the disk when the computer starts too. You can add a security key or a fingerprint below. Both are optional.")

PASSWORD_LABEL = N_("Password")
PASSWORD_FIELD_LABEL = N_("_Password")
CONFIRM_LABEL = N_("_Repeat the password")

PASSWORD_HINT = N_("At least {n} characters. If you forget it, the disk cannot be opened. Nobody can reset it.")
ERR_PASSWORD_EMPTY = N_("Enter a password.")
ERR_PASSWORD_SHORT = N_("The password must be at least {n} characters.")
ERR_PASSWORD_MISMATCH = N_("The two passwords are different.")

KEY_TITLE = N_("Security key (optional)")
KEY_WHAT = N_("A security key is a small USB stick, for example a YubiKey. You tap it to prove it is you.")
KEY_USE = N_("It can unlock the disk when the computer starts, and confirm administrator actions (sudo) and login. The password still always works.")
KEY_STEPS = N_("Plug in the key. Enter its PIN, or choose one if it has none. A PIN is a short code that protects the key; it is not your password. Then tap the key when it blinks, three times in total.")
KEY_NONE = N_("No security key found. Plug it in and wait a moment. If nothing appears, unplug it and plug it in again, or use Check again.")
KEY_FOUND = N_("Found: {name}")
KEY_DONE = N_("Security key registered. It will unlock the disk and confirm administrator actions and login.")

KEY_PIN_LABEL = N_("Key PIN")
KEY_NEW_PIN_LABEL = N_("New key PIN")
KEY_NEW_PIN_HINT = N_("This key has no PIN yet. Choose one with at least {n} characters. It must not be your password.")
ERR_PIN_EMPTY = N_("Enter the PIN of the security key.")
ERR_PIN_SHORT = N_("The PIN must be at least {n} characters.")
ERR_PIN_MISMATCH = N_("The two PINs are different.")

PROBLEM_UNUSABLE = N_("The installer found a device but cannot use it. See the details below.")
PROBLEM_ACCESS = N_("The installer could not read the device. See the details below.")
PROBLEM_LIBRARY = N_("The installer is missing a component needed for this. See the details below.")
SCAN_FAILED = N_("Looking for devices failed: {error}")
SCANNING = N_("Looking for devices...")

FP_TITLE = N_("Fingerprint (optional)")
FP_WHAT = N_("A fingerprint reader is a small sensor, built in or on USB. It is different from a security key.")
FP_USE = N_("A fingerprint can confirm administrator actions (sudo) and login. It cannot unlock the disk when the computer starts. Only your password or a security key can do that.")
FP_STEPS = N_("Choose a finger. Then touch the reader several times as asked, until the progress is complete.")
FP_NONE = N_("No fingerprint reader found. Plug in a USB reader, or skip this step, as it is optional. A security key is not a fingerprint reader.")
FP_FOUND = N_("Found: {name}")
FP_DONE = N_("Fingerprint enrolled. It will confirm administrator actions and login.")

DETAILS_TITLE = N_("Details for troubleshooting")
DETAILS_NO_USB = N_("The installer sees no USB devices.")
DETAILS_USB_SEEN = N_("USB devices the installer sees:")
DETAILS_PROBLEM = N_("Problem: {problem}")

DISABLED_NO_ACCOUNT = N_("Fill in VEKRONA ACCOUNT first.")
NEED_PASSWORD_FIRST = N_("Set the password above first.")
USER_CHANGED = N_("Your username changed. Register the key or fingerprint again.")
WATCH_UNAVAILABLE = N_("Automatic detection is not available. Use Check again.")

STATUS_SET_PASSWORD = N_("Set a password")
STATUS_PASSWORD_ONLY = N_("Password set")
STATUS_WITH_METHODS = N_("Password + {methods}")
STATUS_METHOD_KEY = N_("security key")
STATUS_METHOD_FINGERPRINT = N_("fingerprint")
STATUS_STORAGE_CHANGED = N_("Disk setup changed. Confirm your password.")
STATUS_ENCRYPTION_FAILED = N_("Disk encryption failed. Open this screen.")
NOTICE_ENCRYPTION_FAILED = N_("Disk encryption failed: {error} Click Done to try again, or change the disk setup in Installation Destination.")
STATUS_STORAGE_STILL_PLAIN = N_("The disk setup was applied, but it is still not encrypted with this password.")
STATUS_APPLYING = N_("Setting up disk encryption...")
STATUS_CHOOSE_DISK_FIRST = N_("Set up INSTALLATION DESTINATION first")
STATUS_ENTER_DISK_PASSPHRASE = N_("Enter the disk passphrase")
DISK_TITLE = N_("Disk")
DISK_PASSPHRASE_LABEL = N_("_Disk passphrase")
DISK_CONFIRM_LABEL = N_("Repeat the disk _passphrase")
ERR_DISK_PASSPHRASE_EMPTY = N_("Enter the disk passphrase.")
ERR_DISK_PASSPHRASE_MISMATCH = N_("The two disk passphrases are different.")
DISK_NOTE_PASSPHRASE = N_("You encrypted the disk yourself in Installation Destination. To unlock it with the security key, enter the passphrase you chose there. It must be exactly the same, or the installation fails when it adds the key.")
DISK_NOTE_AUTOMATIC = N_("The disk is encrypted with this password. A passphrase typed on Installation Destination is replaced by it. To keep your own passphrase, choose custom partitioning there.")
NOTICE_PASSPHRASE_REPLACED = N_("The disk was set up with another passphrase on Installation Destination. It was replaced by your password, which now unlocks the disk.")
DISK_NOTE_UNENCRYPTED = N_("The disk setup you chose is not encrypted, so a security key cannot unlock the disk. The key still works for administrator actions (sudo) and login.")
STATUS_PASSWORD_NOT_SAVED = N_("Cannot set the password")
NOTICE_PASSWORD_NOT_SAVED = N_("Cannot set the password: {error}")
STATUS_DISK_PASSPHRASE_NOT_SAVED = N_("Cannot set the disk passphrase")
NOTICE_DISK_PASSPHRASE_NOT_SAVED = N_("Cannot set the disk passphrase: {error}")
STATUS_STATE_UNREADABLE = N_("Cannot read the installer state")
NOTICE_STATE_UNREADABLE = N_("Cannot read the installer state: {error}")

HANDS = (("right", N_("Right")), ("left", N_("Left")))
FINGERS = (
    ("thumb", N_("thumb")),
    ("index-finger", N_("index finger")),
    ("middle-finger", N_("middle finger")),
    ("ring-finger", N_("ring finger")),
    ("little-finger", N_("little finger")),
)
DEFAULT_FINGER = "right-index-finger"


def finger_choices():
    return [
        (f"{hand}-{finger}", _("{hand} {finger}").format(hand=_(hand_name), finger=_(finger_name)))
        for hand, hand_name in HANDS
        for finger, finger_name in FINGERS
    ]


def password_state_error(state, min_length):
    if state is PasswordState.EMPTY:
        return _(ERR_PASSWORD_EMPTY)
    if state is PasswordState.TOO_SHORT:
        return _(ERR_PASSWORD_SHORT).format(n=min_length)
    if state is PasswordState.MISMATCH:
        return _(ERR_PASSWORD_MISMATCH)
    if state is PasswordState.VALID:
        return ""
    raise ValueError(f"Unknown password state: {state}")


def disk_passphrase_state_error(state):
    if state is PasswordState.EMPTY:
        return _(ERR_DISK_PASSPHRASE_EMPTY)
    if state is PasswordState.MISMATCH:
        return _(ERR_DISK_PASSPHRASE_MISMATCH)
    if state is PasswordState.VALID:
        return ""
    raise ValueError(f"Unsupported disk passphrase state: {state}")


def _hint_text(hint_code, no_device_text):
    texts = {
        HintCode.OK: None,
        HintCode.NO_DEVICE: no_device_text,
        HintCode.DEVICE_UNUSABLE: PROBLEM_UNUSABLE,
        HintCode.ACCESS_DENIED: PROBLEM_ACCESS,
        HintCode.LIBRARY_MISSING: PROBLEM_LIBRARY,
    }
    if hint_code not in texts:
        raise ValueError(f"Unknown hint code: {hint_code}")
    text = texts[hint_code]
    return _(text) if text is not None else None


def device_scan_hint_to_key_text(hint_code):
    return _hint_text(hint_code, KEY_NONE)


def device_scan_hint_to_fp_text(hint_code):
    return _hint_text(hint_code, FP_NONE)

# Sign-in methods

Security key, fingerprint and password sign-in, as set up by the installer's VEKRONA SIGN-IN screen and stage `45-auth`.

The installer's **VEKRONA SIGN-IN** screen (which also sets the password) offers to enroll a security
key (YubiKey or equivalent FIDO2 device) or a USB fingerprint reader. Either
device then works for sudo, polkit, the lock screen and the login greeter,
with your password always available as a fallback.

**Security key (FIDO2, PIN + touch):** unlocks the disk at boot and signs you in.
- Disk unlock needs an encrypted disk. With the automatic layout the installer
  already encrypts it with your password. With a custom or Blivet-GUI layout
  that has an encrypted device, the screen asks you to retype the passphrase
  you chose when partitioning, because adding the key to the disk needs it; a
  mistyped passphrase makes the installation fail with a message naming it.
  With a custom layout that is not encrypted, the key does not unlock the disk
  (the screen says so) but still works for sudo and login.
- The installer asks for three touches, all during the install: one to
  create the credential for the disk, one to answer a challenge that derives
  the disk secret (stored in a `systemd-fido2` token keyslot), and one to
  create the credential for sudo and login. The installer writes it to `~/.config/Yubico/u2f_keys`; the first
  `./install.sh 45` moves it into `/etc/u2f_mappings` (below).
- The installer also writes `fido2-device=auto,token-timeout=10s` into the new
  system's `/etc/crypttab` and generates its initramfs with FIDO2 support, so
  the very first boot already asks for the key's PIN and a touch. Without the
  key plugged in, the prompt falls back to the password after 10 seconds; the
  password always works.
- Later, to enroll the key on an already-installed machine, run:
  ```
  pamu2fcfg -o pam://vekrona -i pam://vekrona | sudo tee /etc/u2f_mappings
  sudo systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes /dev/mapper/root
  ```
  Every pam_u2f line (sudo, polkit, the greeter, the lock screen) reads the one registration file
  `/etc/u2f_mappings`, owned by root. A file in your home directory, which any program you run can rewrite, would let
  such a program register a key of its own and sign in as you (and as root through sudo); `./install.sh 45` therefore moves
  your line from `~/.config/Yubico/u2f_keys` into `/etc/u2f_mappings` once, keeps only your own user's line, and
  pam_u2f never reads the old file again. A second key is added with `pamu2fcfg -n -o pam://vekrona -i pam://vekrona | sudo tee -a /etc/u2f_mappings`.
  then rerun `./install.sh 45` to update crypttab and rebuild the initramfs
  (it changes nothing on a system the installer already prepared).
- PAM origin is fixed at `pam://vekrona` so later hostname changes do not break
  key sign-in.
- sudo and polkit go through the system PAM stack (`system-auth`, from the
  `vekrona` authselect profile that stage `45-auth` selects), where the key
  needs its PIN and a touch (`pinverification=1`). The repo ships no PAM file
  for greetd; the Fedora `greetd` package provides it, and it has
  `auth substack system-auth`, so the greeter also asks for PIN and touch.
- The polkit dialog (vekrona-shell) types only into a prompt PAM has asked for. The key check runs
  before the password prompt and can take about 30 s when the key does not answer, so until PAM asks, the field
  is greyed out and the dialog says it is waiting. It then shows PAM's own prompt, so a key's PIN prompt is not
  mistaken for the password. Run `tests/e2e/polkit-dialog.sh` through `vekrona-dev e2e` after changing it.
- Testing in the dev VM: `vekrona-dev usb attach 1050:0407` hands the key to
  the guest. It refuses while a host smartcard daemon (`pcscd`) holds the key
  and names the remedy: `sudo systemctl stop pcscd.socket pcscd.service`.

**Fingerprint (USB reader via libfprint):** signs you in but does not unlock the disk.
- A fingerprint reader returns only match/no-match, not a cryptographic secret,
  so it cannot work with LUKS. If you need disk unlock with biometrics, use a
  FIDO2 key with a built-in fingerprint sensor (a "Bio" key); that is out of
  scope here.
- After install, enroll another finger with `fprintd-enroll <finger>`.

**Lock screen:** `vekrona-lock start` (swayidle starts it on idle and before suspend, and
the lock bindings start it directly). The machine never suspends with the screen unlocked on purpose: the launcher's Sleep, the
sleep key and a closed lid run `vekrona-suspend` (`now` or `--lid`), which locks first. If the screen cannot be locked, the failure is reported in the
robot's error list, a block lock on sleep (`vekrona-lock-guard.service`) keeps the machine awake, and your session stays up; lock
again (Hyper+Escape) or fix the locker, and the block lifts as soon as a lock succeeds. The key needs its PIN and a touch, as for
sudo (`etc/pam.d/vekrona-lock-u2f` has the same pam_u2f arguments as `system-auth`). The one field says above itself what it
expects. With no key plugged in it says "Enter password". With a key plugged in, pam_u2f asks for the PIN at once and the
field says "Enter security key PIN": the PIN and Enter answer it, and the line below then says "Touch your security key"
until the touch. A key has only a few PIN attempts, so a password must not reach it by accident: text counts as the PIN only
if its first character was typed after the PIN prompt appeared (what was typed before was meant as a password, the prompt
arrived while the person was typing it, and goes to the password stack), and Tab turns the field into a password field for
a key that is plugged in ("Enter password"; Tab again goes back). The password field uses its own
password-only stack (`etc/pam.d/vekrona-lock-password`), so a typed password
never reaches the key as a PIN. pam_u2f has no timeout option; when a wait
for the touch ends without one, `vekrona-lock` starts a new one while the key
stays plugged in. A key can also wedge: the attempt shows its cue and then neither
fails nor reacts to touches until the key is replugged. `vekrona-lock` aborts an
attempt that has shown its cue for 40 s without a result and says "Security key not
responding; replug it", without retrying; a replug starts a new attempt. Just before the abort it
logs a stall report (the hung PAM child's state, the key's USB power state, the kernel's USB lines);
read it after unlocking with `journalctl --user -b -t vekrona-lock | grep -A200 'stall report'`.

A YubiKey with its OTP interface enabled is also a USB keyboard: a touch
while no security-key request is pending types a one-time password and Enter,
which the lock screen submits as a wrong password. Vekrona expects OTP off:
run `ykman config usb --disable OTP` once and replug the key; stage 70 fails
while a Yubico device still has a keyboard interface.

**Password:** always works, regardless of key/fingerprint enrollment.

If you enroll neither on the VEKRONA SIGN-IN screen, the machine works
password-only, with no optional keys or fingerprint.

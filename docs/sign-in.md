# Sign-in methods

Security key, fingerprint and password sign-in, as set up by the installer's VEKRONA SIGN-IN screen and stage `45-auth`.

The installer's **VEKRONA SIGN-IN** screen (which also sets the password) offers to enroll a security
key (YubiKey or equivalent FIDO2 device) or a USB fingerprint reader. Either
device then works for sudo, polkit, the lock screen and, if greetd's PAM file
includes the system stack (unverified, see below), the login greeter, with
your password always available as a fallback.

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
  create the credential for sudo and login (`~/.config/Yubico/u2f_keys`).
- The installer also writes `fido2-device=auto,token-timeout=10s` into the new
  system's `/etc/crypttab` and generates its initramfs with FIDO2 support, so
  the very first boot already asks for the key's PIN and a touch. Without the
  key plugged in, the prompt falls back to the password after 10 seconds; the
  password always works.
- Later, to enroll the key on an already-installed machine, run:
  ```
  pamu2fcfg -N -o pam://vekrona -i pam://vekrona > ~/.config/Yubico/u2f_keys
  sudo systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes /dev/mapper/root
  ```
  then rerun `./install.sh 45` to update crypttab and rebuild the initramfs
  (it changes nothing on a system the installer already prepared).
- PAM origin is fixed at `pam://vekrona` so later hostname changes do not break
  key sign-in.
- sudo and polkit go through the system PAM stack (`system-auth`, from the
  `vekrona` authselect profile that stage `45-auth` selects), where the key
  needs its PIN and a touch (`pinverification=1`). The repo ships no PAM file
  for greetd; the Fedora `greetd` package provides it. That greetd's PAM file
  includes `system-auth`, so the greeter also asks for PIN and touch, is
  unverified.
- Testing in the dev VM (`iso/dev-vm.sh`): USB passthrough of the key fails
  while a host smartcard daemon (`pcscd`) holds it. `dev-vm.sh up` refuses and
  names the remedy: `sudo systemctl stop pcscd.socket pcscd.service`.

**Fingerprint (USB reader via libfprint):** signs you in but does not unlock the disk.
- A fingerprint reader returns only match/no-match, not a cryptographic secret,
  so it cannot work with LUKS. If you need disk unlock with biometrics, use a
  FIDO2 key with a built-in fingerprint sensor (a "Bio" key); that is out of
  scope here.
- After install, enroll another finger with `fprintd-enroll <finger>`.

**Lock screen:** touch-only (no PIN prompt, `etc/pam.d/dankshell-u2f`) to avoid burning through FIDO2 PIN
retries on mistyped patterns. The screen sends its password answer to every
PAM prompt, so a PIN dialog would lock you out after too many wrong answers.

**Password:** always works, regardless of key/fingerprint enrollment.

If you enroll neither on the VEKRONA SIGN-IN screen, the machine works
password-only, with no optional keys or fingerprint.

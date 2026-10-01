# Install on a MacBook (2013–2015)

What stage `15-mac` does on a 2013–2015 MacBook Pro, and what to check on real hardware.

This targets Intel MacBook Pro models from 2013–2015 (non-T2, MacBookPro11,x and
12,1). MacBook Air models and T2 Macs (2018–2020, Touch ID) are out of scope: T2
Macs need a patched kernel and a Secure Enclave proxy. Everything below is
untested on hardware unless it says otherwise.

**Before install:**
- Update the firmware to the latest macOS version before you wipe the disk
  (recovery holds older firmware).
- Wi-Fi decides what you need on day one:
  - BCM4360 (`14e4:43a0`, MacBookPro11,1 to 11,3) has no in-kernel driver. It
    needs `wl` from RPM Fusion (`akmod-wl` build -63 or later on kernel 7.2+).
    Anaconda cannot load it, so installation and the first boot both need
    Ethernet (a Thunderbolt or USB adapter) or USB tethering. Wi-Fi works only
    after stage 15 has built `wl` and you have rebooted. Stage 15 checks the
    network first and dies with a message naming Ethernet or tethering if there
    is none.
  - BCM43602 (`14e4:43ba`, MacBookPro11,4, 11,5 and 12,1) works out of the box
    with `brcmfmac`. Stage 15 installs
    `etc/systemd/system-sleep/vekrona-brcmfmac-resume`, which reloads the driver after resume.
- The machine has no built-in fingerprint reader. A USB reader supported by
  libfprint (check its lsusb ID at
  https://fprint.freedesktop.org/supported-devices.html) works for sudo and
  login, never for disk unlock. A security key (FIDO2) can unlock the disk.

**Boot:** hold Option at power-on and pick "EFI Boot" to boot the install media.

**What stage 15-mac does:**
- Builds the Broadcom `wl` Wi-Fi module when a BCM4360 is present and fails
  loudly if the module is missing for the target kernel.
- Sets `apple-gmux force_igd=y` on dual-GPU models, so the Intel GPU is primary.
  The proprietary NVIDIA driver is skipped on Macs: the GT 750M needs the 470
  legacy driver, which does not build on kernel 7.x, so nouveau binds instead
  (stage 10-nvidia does not run).
- Builds the FaceTime HD camera driver from a pinned patjak/facetimehd 0.7.2
  source as DKMS, and extracts the camera firmware from Apple's download. Both
  downloads are verified by sha256.
- Installs Intel VA acceleration (`libva-intel-driver`).
- On MacBookPro12,1, adds the audio quirk `snd_hda_intel model=mbp11`.

**Display and input:** `lib/display-scale.sh` reads the internal panel's
resolution and physical size from DRM and its EDID, and writes
`~/.config/sway/config.d/vekrona-panel-scale.conf` with scale 2 when the panel
is at least 192 DPI, otherwise scale 1. The touchpad uses tap-to-click,
natural scroll and `click_method clickfinger`. The keyboard backlight keys call
`brightnessctl --device='smc::kbd_backlight'`.

**Known gaps:** fan control, suspend/resume and the items in the checklist below
are open in [TODO.md](../TODO.md).

## Real MacBook checklist

Run after the install and report what fails:

1. `cat /sys/class/dmi/id/product_name` and `lspci -nn -d 14e4:` (Wi-Fi
   `43a0` or `43ba`, camera `1570`).
2. `./install.sh --list` shows `15-mac` and not `10-nvidia`.
3. Wi-Fi connects, then still works after a suspend and resume.
4. After a kernel update and before rebooting, run `modinfo -k <new kernel> wl`
   (BCM4360 only) and `modinfo -k <new kernel> facetimehd`.
5. The Intel GPU is primary, and the dGPU is powered down:
   `sudo cat /sys/kernel/debug/vgaswitcheroo/switch`.
6. `v4l2-ctl --list-devices` lists the FaceTime HD camera, and an app shows
   a picture.
7. Audio plays and the microphone records (MacBookPro12,1 quirk).
8. The fn keys work: volume, brightness, keyboard backlight.
9. The display scale is right (2 on Retina) and the touchpad clicks with
   one and two fingers.
10. `sensors` under load: fans spin up and temperatures stay sane.
11. Hold Option at power-on: the picker lists the Fedora entry.
12. With a USB fingerprint reader: `fprintd-enroll`, then `sudo` accepts a
    finger.
13. Battery: the screen dims and the machine suspends at the idle timeouts.

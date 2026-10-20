# Calendar

The bar's Calendar widget shows your next event today and opens a month grid with an agenda for the next 31 days.
It reads `~/.local/state/vekrona/calendar.json`, which `vekrona-calendar` writes 30 seconds after login and then every hour
(`vekrona-calendar.timer`, which runs only while your Sway session does, so a laptop on battery is not woken for it while you are logged out). Vekrona syncs calendars with [vdirsyncer](https://vdirsyncer.pimutils.org/) into
`~/.local/share/vekrona-calendars/<provider>/` and reads them with [khal](https://khal.readthedocs.io/).
All providers are read-only: Vekrona shows events, it does not create or change them.

## Set up

1. Copy the example (the install links it from the checkout it ran from): `cp ~/.config/vdirsyncer/config.example ~/.config/vdirsyncer/config`.
2. Replace every `PLACEHOLDER` of the providers you use. You do not have to delete the others: a provider whose
   pair still holds a `PLACEHOLDER` in one of its storages is unused and Vekrona skips it silently, so leave the
   unused template providers as they are. The file holds secrets (URLs and passwords), so it stays yours and Vekrona
   never overwrites it.
3. Run `vdirsyncer discover <pair>` once by hand for each pair you filled in (for example `vdirsyncer discover proton`;
   without a pair name it also tries the placeholder pairs and fails). The unit never runs it, because it can prompt and hang.
4. Run `systemctl --user start vekrona-calendar.service`. It syncs, then renders `calendar.json`, so the widget
   updates at once. After that the timer keeps it fresh.

A pair is `[pair X]` with its two storages `a` and `b`. The calendar is configured when at least one pair has no
`PLACEHOLDER` in either storage, and each sync runs `vdirsyncer metasync` and `vdirsyncer sync` for those pairs
only, by name. Commented lines do not count. A pair that names a storage the config does not define is an error,
not a skip: the sync and the unit fail and `vekrona-error` records it.

Until `~/.config/vdirsyncer/config` exists and has one such pair, the popout says "No calendars yet. See docs/calendar.md."
The unit is skipped, not failed, in that state: `ExecCondition=vekrona-calendar configured` exits 1, which systemd treats as "condition not met".
If a sync fails, the unit fails and `vekrona-error` records it; the widget keeps showing the last synced events.
Running `vekrona-calendar sync` by hand while `~/.config/vdirsyncer/config` is missing, or while every pair still holds a `PLACEHOLDER`, fails (only the unit is skipped, through `ExecCondition`).

## Providers

### Proton

Proton Calendar has no CalDAV, so Vekrona subscribes to a share link.

1. In the Proton Calendar web app (the mobile apps cannot create the link), open Settings, Calendars, your calendar.
2. Under "Share via link" create a link with "Full view" access and copy it.
3. Paste it as the `url` of `[storage proton_remote]`.

The Proton Mail desktop app (it includes Proton Calendar) shows its own calendar reminders; the bar widget does not
read from it and stays fed by this ICS link.

Caveats:

- Choose "Full view". "Limited view" only shows busy and free blocks, without titles.
- Share links need a paid Proton plan, and the link is read-only.
- A calendar can have at most 5 links.
- Proton refreshes the link only every few hours, so changes can take up to 8 h to show up.
- If the link stops updating, delete it and create a new one, then paste the new URL into the config.

### Google

1. In Google Calendar on the web, open Settings, your calendar, Integrate calendar.
2. Copy the "Secret address in iCal format" into `[storage google_remote]`.

Caveats: the calendar is read-only here. Anyone who has the secret address can read your whole calendar, so keep the
config file private and reset the address in the same settings page if it leaks.

### iCloud

1. At appleid.apple.com, Sign-In and Security, create an App-Specific Password.
2. Put your Apple ID in `username` and the password in `password` of `[storage icloud_remote]`.

### Nextcloud

1. In Settings, Security, create an app password.
2. Put your server in `url` (`https://HOST/remote.php/dav`, replacing `PLACEHOLDER` with your host), your user name in `username` and the app password
   in `password` of `[storage nextcloud_remote]`.

### Microsoft

1. In Outlook on the web, open Settings, Calendar, Shared calendars, Publish a calendar.
2. Publish the calendar and copy the ICS link into `[storage microsoft_remote]`.

Caveats: the link is read-only and Outlook refreshes it slowly (about 3 h or more). Many Microsoft 365 work
tenants disable publishing, and then this provider is not available to you.

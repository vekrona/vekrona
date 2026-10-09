# Calendar

The bar's Calendar widget shows your next event today and opens a month grid with an agenda for the next 31 days.
It reads `~/.local/state/vekrona/calendar.json`, which `vekrona-calendar` writes every 15 minutes
(`vekrona-calendar.timer`). Vekrona syncs calendars with [vdirsyncer](https://vdirsyncer.pimutils.org/) into
`~/.local/share/vekrona/calendars/<provider>/` and reads them with [khal](https://khal.readthedocs.io/).
All providers are read-only: Vekrona shows events, it does not create or change them.

## Set up

1. Copy the example: `mkdir -p ~/.config/vdirsyncer && cp ~/.local/share/vekrona/config/vdirsyncer/config.example ~/.config/vdirsyncer/config`.
2. Keep the pairs and storages of the providers you use and delete the others. Replace every `PLACEHOLDER`.
   The file holds secrets (URLs and passwords), so it stays yours and Vekrona never overwrites it.
3. Run `vdirsyncer discover` once by hand. The unit never runs it, because it can prompt and hang.
4. Run `systemctl --user start vekrona-calendar.service`. It syncs, then renders `calendar.json`, so the widget
   updates at once. After that the timer keeps it fresh.

Until `~/.config/vdirsyncer/config` exists, the popout says "No calendars yet. See docs/calendar.md."
If a sync fails, the unit fails and `vekrona-error` records it; the widget keeps showing the last synced events.

## Providers

### Proton

Proton Calendar has no CalDAV, so Vekrona subscribes to a share link.

1. In the Proton Calendar web app (the mobile apps cannot create the link), open Settings, Calendars, your calendar.
2. Under "Share via link" create a link with "Full view" access and copy it.
3. Paste it as the `url` of `[storage proton_remote]`.

Caveats: share links need a paid plan, the link is read-only, and Proton refreshes it only every few hours
(up to 8 h), so new events appear late.

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
2. Put your server in `url` (`https://HOST/remote.php/dav`), your user name in `username` and the app password
   in `password` of `[storage nextcloud_remote]`.

### Microsoft

1. In Outlook on the web, open Settings, Calendar, Shared calendars, Publish a calendar.
2. Publish the calendar and copy the ICS link into `[storage microsoft_remote]`.

Caveats: the link is read-only and Outlook refreshes it slowly (about 3 h or more). Many Microsoft 365 work
tenants disable publishing, and then this provider is not available to you.

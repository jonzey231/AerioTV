# Aerio Roadmap

Features planned for future releases. Items here are committed to happen
but don't have a firm timeline. If you'd like one prioritised, open an
issue on GitHub.

## Planned

### Chromecast support
Cast live channels and VOD content to Google Chromecast devices from
iPhone, iPad, and Mac. Currently untested; requires the Google Cast
SDK integration plus end-to-end testing on real hardware.

### Xtream Codes category/genre EPG coloring
Category-based guide coloring currently works for M3U + XMLTV sources.
Xtream Codes' `get_short_epg` endpoint does return a `genre` field
that Aerio doesn't parse yet — wiring it through will light up the
category colors for XC sources too.

### iCloud sync of category color customisations
The Settings → Guide Display palette customisation is currently
per-device. Sync the four `categoryColor.*` UserDefaults keys via the
existing `SyncManager` so a user's custom palette appears on every
device they own.

### Better deep-link handling when the On Demand tab is hidden
If a user launches Aerio from a Top Shelf VOD entry while the active
server has no VOD library, the tab selection is set internally but
the tab isn't mounted. Either force a VOD re-fetch before switching,
or surface a brief toast explaining why the tap did nothing.

## Under consideration

### Per-tile audio picker in multiview
Today multiview assigns audio to whichever tile was added last. Let
users explicitly pick the audio tile from a multiview action sheet.

### Simulator-aware WiFi detection warning
The "Wi-Fi detected but SSID unknown" warning assumes Location
permission is the cause. Detect iOS Simulator and airplane-mode edge
cases so the warning points users at the real fix.

## Recently shipped

See [CHANGELOG.md](CHANGELOG.md) for everything that's already landed.

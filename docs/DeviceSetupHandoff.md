# Set up another device

Wire format version 1. This file is identical in the Android repo
(`docs/DeviceSetupHandoff.md`) and the Apple repo
(`docs/DeviceSetupHandoff.md`). Change both in the same session.
Checked against Apple `6527977` and Android `de85e07f` on 2026-11-11.
"Receiver apply" step 1 also describes the phones after this release's
later fixes: keyless profiles held, an active Child kept, and the saved
sync copy discarded (Apple `4ecddec`, `8812f05`, `62510db`, and `0d67843`;
Android `ab45038e`, `aa22d817`, and `c48fbef9`; no request to a held
address, logos included, Apple `150a1e1`, Android `cf7cb482`). Fix
Login "On the TV" items 1, 4, and 5 describe the phones after this
release's fix that reconnects only the playlist's current account
(Apple `5568737`, Android `9baa05f4`), with the prompt for a Child
(Android `b106e0bc`; the rest, Apple `dbeb080`, Android `1bedca29`).
Fix Login item 4 also lifts only the playlist's own rejected-key
hold, never a profile's (Apple `78cabaf`, Android `1198bfe2`). Item 1
also describes the prompt for an active non-default profile's own
refused key, whose Sign In signs in only that profile (Apple
`78cabaf`, Android `7186006e`). After this release's last fixes, item 1
also drops that prompt's Edit Playlist clause and, for an Admin or
Standard profile, its "Edit Playlist" and "Update from Phone" buttons,
and a switch to a profile whose key is held as rejected opens that
profile's form first (Apple `cd2be4d` and `1359259`, Android `48d88962`
and `10055663`).

## Why

Typing a server URL, an API key, and every profile's password with a TV
remote is the reason sync exists, yet a new TV still had to be typed into
once. With this flow any AerioTV device that already has the playlist sends
it, its profiles, and the sync choice to another device (TV, phone, or
tablet) over the local network.

## Roles

| Side | Who | What it does |
|------|-----|--------------|
| Receiver | Every device (Android TV, Apple TV, Android phone and tablet, iPhone, iPad) | Welcome > "Set up from another device", and on phones and tablets also Add Playlist > "Set up from another device". On TVs also the rejected-key prompt's "Update from Phone" (see Fix Login). Generates a code and key pair, listens, advertises, shows a QR code and the code, applies the payload. |
| Sender | Phone or tablet (Android, iPhone, iPad) | Settings > Playlists > "Set up another device" (list and playlist detail; an Admin or Standard profile, or the default profile), a dock card directly above the tab bar while another device is advertising (one row: that device's name, Set up, and dismiss; it shares a row with the Control a TV button when that button shows), a banner at the top of the Settings root for the same device (the device-type icon, the name, Set up, and dismiss; one shared discovery, gating, and dismissal with the dock card; the key check is on the next screen, "Check that the device shows XXXX"), and "Set up another device with this playlist" on the phone onboarding's Add Profiles step. The dock card and banner read "Fix Login" for a TV asking for a sign-in (see Fix Login). A device never lists its own advert. |

## Receiver session

1. Generate a 6-digit code (`000000` to `999999`, zero padded, from a
   cryptographically secure source) and an X25519 key pair.
2. Start an HTTP/1.1 listener on an ephemeral port on all interfaces.
   Android uses the app's Ktor CIO server; Apple uses `NWListener`.
3. Advertise DNS-SD service type `_aeriotv-setup._tcp` on that port, with
   instance name = the device name and these TXT keys:

   | Key | Value |
   |-----|-------|
   | `v` | `1` |
   | `name` | device name (at most 60 characters) |
   | `pk` | receiver public key, 32 raw bytes, standard base64 with padding |
   | `kind` | `phone`, `tablet`, or `tv` (iPad and Mac count as `tablet`). Absent or unknown reads as `tv`, which is what builds before this key advertised. The sender shows a device-type icon from it. |
   | `mode` | Optional. Absent (or blank) = a setup receiver, which is every build before this key. `fixlogin` = a TV asking for one playlist's sign-in (see Fix Login). Senders do not offer an advert whose `mode` they do not know. |
   | `pl` | With `mode`=`fixlogin`: the id of the playlist whose sign-in is wanted (UUID, lowercase). Not a secret. |

   The TXT record carries nothing derived from the code.
4. Show the QR code, the code in large type, next to it the key
   fingerprint as "Key XXXX" (see Security), the device name, and the line
   "Open AerioTV on your other device, then Settings > Playlists > open
   your playlist > Set up another device, or scan this code."
5. When the device has no LAN address it shows "This device is not on a
   network" and "Connect this device to the same network as your other
   device, then try again."
6. The session lasts 10 minutes, then shows "The setup code expired" with
   New Code and Cancel. Cancel returns to where the screen was opened (Welcome or Add Playlist). Leaving the screen stops
   the listener and the advert.

The companion remote host (`_aeriotv._tcp`) is a separate service and is
not involved.

## QR code and URL scheme

```
aeriotv://setup?v=1&ip=<lan ipv4>&port=<port>&code=<6 digits>&pk=<base64url pk>&name=<url-encoded name>
```

`pk` here is base64url without padding. Readers accept standard or URL-safe
base64, padded or not, for every key field. The QR is generated on the receiver
(error correction H); no network call is made.

The sender registers the `aeriotv` scheme with host `setup`, so the system
camera opens AerioTV on the Set up another device screen with the device and
code already filled in. On phones and tablets the Set up another device screen also has
"Scan QR code" (in-app camera scanner), "Choose from Photos" (system photo
picker), and "Import file" (system document picker, a text file holding the
link). The discovered device list plus typing the code is the fallback on every
platform.

### Related: Dispatcharr user QR

Dispatcharr's web UI (User modal, Dispatcharr dev commit 52bdb33e) shows a QR
for a user's API key. Its text is JSON:
`{"v":1,"type":"user_api_key","api_key":"<key>","base_url":"<https://server>","username":"<advisory>","first_name":"","last_name":"","email":""}`.
A client parses it as JSON and accepts it only when `type` is `user_api_key`
and `v` is 1; it then uses `api_key` with `base_url`. The identity fields are
advisory and may be blank, and a long payload may be trimmed to `api_key`
and `base_url` only. The same payload may also arrive as a file or as text
instead of an image. AerioTV reads this code and the `aeriotv://setup` code
through three inputs, all with one parser (phones and tablets; TVs have none
of them). Where these buttons appear they come in this order: Scan QR code,
Choose from Photos, Import file, Show User QR Code (see below). Import is manual only: AerioTV is not a share target and never
reads the clipboard.

The display draws the code at error correction level H with the AerioTV mark centered on a rounded white plate covering 20 percent of the code's width (mark inset 12 percent of the plate), so the payload is unchanged and still scans.

1. Camera: the in-app scanner ("Scan QR code").
2. Photos: a QR code image from the system photo picker ("Choose from
   Photos").
3. File: the system document picker ("Import file"; `application/json`,
   `text/plain`, any type as a fallback). At most 64 KiB is read; the file
   holds the JSON above or a setup link (a link may sit among other text).
   Anything else shows "That file is not a Dispatcharr user code or an
   AerioTV setup code."

After a successful import from Photos, AerioTV asks "Delete this image from
Photos? It contains your sign-in code." with Delete and Keep. Delete hands
the image to the system delete request (Android 11 and later), so the system
asks for confirmation and the OS deletes it; Android 10 and earlier get no
prompt. After a successful Import file, the same offer ("Delete this file?
It contains your sign-in code.") appears only when the document picker
granted a URI that supports deletion; otherwise there is no prompt. Nothing
is deleted without the user's tap, and the log records only whether the
source was deleted or kept, never its path.

A user code fills the Dispatcharr connect form or an Add Profile form and
signs in the same way as a typed key; a setup code opens Set up another device;
anything else shows "This is not a Dispatcharr user code or an AerioTV setup
code." The key is never logged. After a QR sign-in the existing App Data list
(`/api/accounts/users/me/app-data/`) tells the app whether the user already
has AerioTV sync data, and if so Dispatcharr Sync is offered as a restore.

## Sender flow

1. Browse `_aeriotv-setup._tcp`; list each device by `name` with its
   device-type icon (from `kind`) and the subtitle "Check that the device
   shows XXXX", where XXXX is the key fingerprint computed from the
   advertised `pk`. Ignore adverts whose `v` is not `1`, whose `pk` is not
   32 bytes, or whose `pk` is this device's own receiver key.
2. Pick a device from this list, the dock card, or the banner.
3. Dispatcharr only (other playlist types skip this step): choose the
   scope, one of two radio buttons:
   - "Copy entire setup from this device" (default): the playlist plus
     every profile on this device with its credentials, roles, avatars,
     PINs, and order, with every sendable profile and the sync choice
     preselected in step 5.
   - "Import this user only": the playlist plus the active profile only;
     step 5 hides the profile checklist and keeps the sync choice.
     When the active profile has no saved sign-in here, the sender first
     shows the profile roster's sign-in prompt for it, saves the sign-in,
     and continues; Cancel returns to this step. The active profile's own
     sign-in becomes the playlist sign-in, never the default profile's.
   Both are the same version 1 payload; the second simply carries one
   profile.
4. Enter the code shown on the device. The sender does not check the code
   locally; only the receiver verifies it, by decryption (a typo spends
   one of its 3 attempts). A QR link skips code entry.
5. Choose what to send:
   - The playlist, always.
   - Dispatcharr, "Copy entire setup" only: a checkbox per local profile
     of that playlist. The default profile is always sent (it signs in
     with the playlist login). Each row says "API key saved", "Password
     saved", or that no sign-in is saved here (such a row cannot be sent).
   - Dispatcharr only: "Turn on Dispatcharr Sync on the other device",
     preselected when Dispatcharr Sync is on here.
6. Send. Results: sent ("The device is finishing setup now"), wrong code
   (back to code entry), "The device is no longer waiting", or "The device
   could not be reached".

## Crypto

All keys are raw 32-byte X25519 keys (RFC 7748; CryptoKit
`Curve25519.KeyAgreement` on Apple; on Android a small RFC 7748
implementation, because the platform `XDH` KeyAgreement needs API 33).

```
shared   = X25519(phonePriv, tvPub)            // == X25519(tvPriv, phonePub)
info     = ASCII("aeriotv-setup-v1") || phonePk(32) || tvPk(32)
key      = HKDF-SHA256(ikm = shared, salt = ASCII(6-digit code), info, L = 32)
nonce    = 12 random bytes
sealed   = AES-256-GCM(key, nonce, plaintext = payload JSON UTF-8, no AAD)
ciphertext = sealed ciphertext || 16-byte tag   // CryptoKit combined minus the nonce
```

The phone generates a fresh key pair for every send. An all-zero shared
secret is rejected.

## Request and response

`POST http://<ip>:<port>/setup`, `Content-Type: application/json`, body at
most 256 KB, no `Origin` header (a request with `Origin` is refused, which
keeps web pages on the LAN out):

```json
{ "v": 1, "phonePk": "<base64>", "nonce": "<base64>", "ciphertext": "<base64>" }
```

| Status | Body | Meaning |
|--------|------|---------|
| 200 | `{"ok":true}` | Decrypted and accepted. The receiver stops advertising and applies it. |
| 403 | `{"ok":false,"error":"wrong_code"}` | Decryption failed: the code (or key) does not match. |
| 403 | `{"ok":false,"error":"forbidden"}` | This code was already used, or the request carried `Origin`. |
| 400 | `{"ok":false,"error":"bad_request"}` | Not a version 1 envelope, bad base64, or bad payload JSON. Not counted as an attempt. |
| 413 | `{"ok":false,"error":"too_large"}` | Body over 256 KB. |

Code verification is the AEAD tag: the key depends on the code, so a
successful decrypt proves the phone used the code on screen. One success
per code; after 3 wrong-code failures the receiver generates a new code and key
pair and re-advertises.

## Payload (plaintext JSON)

Unknown keys are ignored by readers; absent keys take the defaults shown.

```json
{
  "playlist": {
    "id": "6F1C2A4E-0B7D-4E52-9C1A-2D3E4F5A6B7C",
    "type": "dispatcharr | xtream | m3u",
    "name": "Home",
    "url": "https://server.example",
    "localUrl": "http://<lan-address>:<port>",
    "guideDays": 7,
    "catchupOffsetMinutes": 0,
    "vodEnabled": true,
    "channelProfileIds": [2],
    "credential": { "apiKey": "...", "username": "...", "password": "..." }
  },
  "profiles": [
    {
      "id": "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
      "username": "alex",
      "displayName": "Alex",
      "role": "admin | user | child",
      "avatar": { "icon": "initial", "color": "" },
      "order": 0,
      "isDefault": true,
      "pinType": "numbers | directions | none",
      "pinHash": "<64 hex>",
      "pinSalt": "<32 hex>"
    },
    {
      "username": "sam",
      "displayName": "Sam",
      "role": "child",
      "order": 1,
      "isDefault": false,
      "credential": { "apiKey": "..." },
      "pinType": "none", "pinHash": "", "pinSalt": ""
    }
  ],
  "sync": { "provider": "dispatcharr", "enabled": true }
}
```

Notes:

- `playlist.id` is the sender's playlist id (its UUID string) and
  `profiles[].id` each profile's id. Both are optional: older senders omit
  them. "Import this user only" for a profile other than the default omits
  both (another user's sign-in is another account, so another playlist).
  Ids compare without case (Apple writes uppercase, Android lowercase).
- `playlist.credential` is the playlist's own sign-in: the default
  profile's API key and/or username and password on Dispatcharr, the
  account login on Xtream Codes, absent on M3U. Only non-empty fields are
  sent.
- `xmltvUrl`, `localUrl`, and `userAgent` are sent only when set; senders never write `null`.
- `guideDays` uses the stored Guide Days value (1 to 14, or 0 for All
  Available). `channelProfileIds` holds the playlist's Dispatcharr Channel
  Profile (empty = all channels).
- Profiles: `credential` is absent on the default profile and carries
  `apiKey`, `password`, or both otherwise (a receiver tries the key
  first). PIN fields are the same v2 hash and salt Dispatcharr Sync
  carries in the `profiles` key; a PIN set before sync that has not been
  re-entered yet is sent as `none`. `order` is the profile's position
  among every local profile of the playlist.
- "Import this user only" sends one entry, marked `isDefault` true with
  `order` 0 and no `credential`; `playlist.credential` carries that
  user's sign-in.
- XC and M3U playlists send `playlist` only.
- `sync` is present only when the user chose to turn it on.
- `mode` is optional: absent = a setup (every sender before Fix Login);
  `fixlogin` = only `playlist` and its `credential`, with no `profiles` and
  no `sync` (see Fix Login).

## Receiver apply

Non-interactive, with a progress line on screen:

1. "Connecting to your server": add the playlist through the normal Add
   Playlist save path (it loads the channels, which is the connection
   test), then store the catch-up offset. On failure: "Setup did not
   finish" with the error, Retry (re-applies the same payload), and Cancel.
   Playlist id: when a playlist here already has `playlist.id`, it is the
   same playlist and is updated in place (Replace, "Updating your
   playlist"), never added a second time and never prompted. Otherwise the
   duplicate check (same server and account, Cancel, Add Anyway, or
   Replace) runs against playlists with other ids, and a new playlist is
   created with the sender's `playlist.id`, its default profile with the
   default entry's `id`, and each added profile with its `id` (an id
   already used here gets a new one). Without ids, today's behavior.
   When the update changes the scheme, host, or port of the playlist's
   server URL or local URL, every non-default profile is held, with or
   without a stored sign-in (a held sign-in is never sent), a non-default
   active profile switches to the default (an active Child instead stays
   active and held, and leaving it needs the usual PIN; while it is held,
   no request of any kind, logos included, goes to the playlist's
   addresses except the same-server check and its own sign-in form), and
   the saved Dispatcharr Sync copy of the server's record is discarded for
   every profile of the playlist, all before anything but requests with
   the payload's own playlist sign-in goes to the new address. When
   `users/me` at the new address, with the default profile's sign-in,
   returns the user id and username recorded before the change began (no
   `users/me` made during the change, or while any profile is held,
   updates that record), the holds lift for the profiles last signed in
   at that server; otherwise a held profile asks to sign in again when
   picked, and that sign-in must name the profile's own user (another
   account is refused and nothing is written).
2. "Adding profiles": entries sorted default first, then every non-Child
   (Admin and Standard together), then Child, each group by `order`
   (-1 last). Child last lets the rule "while a Child exists, every Admin
   and Standard profile holds a PIN" pass, because their PINs arrive
   first.
   - Default entry: applied to the local default profile: display name
     when not blank, role when the wire value is valid (resolved against
     the server level), order when 0 or more, the avatar when present, and
     the PIN when `pinType` is `numbers` or `directions` with a
     64-character hash and a 32-character salt (Apple accepts any
     non-empty salt here). Android stamps its synced roster row; Apple does
     not.
   - Any other entry: when a profile with that username already exists
     here, Android skips it and Apple applies its name, role, avatar,
     order, and PIN to the existing profile. Otherwise it goes through the
     roster add path (signs in once with the sent credential, `/me/` must
     name the same user, then applies role, PIN, avatar, display name, and
     order, and keeps the sent `id` when it is free here).
   A profile that fails is skipped and logged; the rest continue.
3. Dispatcharr Sync: `sync.enabled` never turns it on. When the payload
   carries `sync` with `provider` `dispatcharr` and `enabled` true,
   Dispatcharr Sync is off here, and the owner has not declined before,
   the receiver asks once after the apply, "Dispatcharr Sync is on for
   this account" / "Another device already syncs this account through
   Dispatcharr. Turn it on here too?" (Android with Google Drive on: "Turn
   it on here too, alongside Google Drive?"; Apple with iCloud on: "Turn
   it on here too, alongside iCloud?"), with Turn On and Not Now. Turning
   it on never changes Google Drive or iCloud.
4. Continue into the onboarding Add Profiles step (server user list,
   search, and QR import), so users whose credentials were not sent can be
   added exactly as in onboarding. Then finish onboarding, or return to
   Settings when the device was already set up, and open the main screen
   (the profile picker shows when the playlist asks for it).

## Fix Login

A TV whose playlist's API key the server rejected (the rejected-key hold:
"API key no longer valid", every API call for that playlist held locally) and
that has no stored password that could sign in again on its own gets the
working sign-in from a phone or tablet that has one. Same receiver, sender,
code, crypto, envelope, and replies as a setup; only the advert, the payload,
and the apply differ. Both new fields are optional, so older receivers,
senders, and other ports keep working: a receiver that never advertises
`mode` is a setup receiver, and a payload without `mode` is a setup. Works
across platforms (an iPhone can fix an Android TV and the reverse).

On the TV:

1. The rejected-key prompt (title "API key no longer valid") says "Dispatcharr no longer accepts
   the API key for <playlist>. It may have been changed on the server. Sign in with your
   Dispatcharr username and password to reconnect, or enter the current key in Edit Playlist."
   When a stored password was refused too, it says "the sign-in for <playlist>" and "the current
   details". When a stored password signs in but the account has no API key, it says "This account
   has no API key yet. Ask your Dispatcharr administrator to turn on API access for it." Buttons on
   TVs: "Update from Phone" (primary, default focus), "Sign In with Remote" (opens the "Sign in to
   Dispatcharr" form), and "Not Now", in that order. Phones and tablets: "Sign In" (primary, the
   same form), "Edit Playlist", and "Not Now". A profile that fails the Set up gate (a Child that
   is not the default profile), or the app behind the launch PIN, gets no sign-in button.
   For a Child, the first two bodies above are cut, with no new words: when Sign In is offered (a
   default Child) the body ends "... Sign in with your Dispatcharr username and password to
   reconnect.", and when it is not, the body ends after "It may have been changed on the server."
   A Child gets no "Edit Playlist" button (Apple `dbeb080`, Android `b106e0bc`; the cut body,
   Apple `dbeb080`, Android `1bedca29`). For the playlist's own refused key (the default
   profile's), the form reconnects only the playlist's current account. After the login and
   `users/me`, and before anything is written, `users/me` must name the playlist's known user: the
   default profile's recorded account (user id and username, see "Receiver apply" step 1), else
   the playlist's own stored username, else the default profile's username, never a value a
   non-default profile could have written. Usernames compare without regard to case, and the user
   id too whenever one is recorded. Any other account is refused with "Dispatcharr did not accept
   that username or password.", its token is dropped, and nothing is written. With no known user,
   a Child (active or default) is refused and anyone else may sign in, as before. Changing which
   account a playlist uses stays in Edit Playlist, which a Child cannot open (Apple `5568737`,
   Android `9baa05f4`; the known-user order, Apple `1c8430e`, Android `ff7ad987`).
   When the refused key is an active non-default profile's own, the prompt belongs to that
   profile: its Sign In (offered under the same Set up gate, so never to a Child) opens the form
   for that profile's own username, which signs in only that user (another account is refused and
   nothing is written); a passed sign-in stores that profile's new key and password and lifts only
   that profile's hold (Apple `78cabaf`, Android `7186006e`). Its body drops the Edit Playlist
   clause, as a default Child's does, so it ends "... Sign in with your Dispatcharr username and
   password to reconnect." (a non-default Child's body is cut further, as above). For an Admin or
   Standard profile it shows no "Edit Playlist" or "Update from Phone" button, because those
   repair only the playlist's own sign-in: its buttons are "Sign In" (phones and tablets) or "Sign
   In with Remote" (TVs), then "Not Now". A non-default Child keeps the buttons it had: "Not Now"
   on phones and tablets, and "Update from Phone" and "Not Now" on TVs. Choosing a profile whose
   key is held as rejected, in the switcher or the launch picker, opens its "Sign in to
   Dispatcharr" form once its PIN passes, before playback stops or anything is sent: that
   profile's own form (its username only) for a non-default profile, or the form above (the
   playlist's known user) for the default profile. A passed sign-in replaces only that profile's
   key and lifts only its hold, and Cancel keeps the current profile. A Child target gets the form
   too, because an Admin or Standard profile, or a PIN from one, made the choice (Apple `cd2be4d`
   and `1359259`, Android `48d88962` and `10055663`).
2. "Update from Phone" opens the receive screen (QR code, code, key
   fingerprint, device name) for that playlist with the header "Update from
   your phone" and the line "On your phone, open AerioTV and tap Fix Login."
   Cancel returns to the guide.
3. The advert adds `mode`=`fixlogin` and `pl`=the playlist id.
4. Apply: only the sign-in of the playlist with `playlist.id`, which must be
   the playlist the screen was opened for (ids compare without case): the
   API key, and the username and password when sent. A field not sent, or
   sent blank, keeps its stored value. Before anything is written, the TV
   verifies the sent sign-in at the playlist's address (`users/me` with
   the sent key, or a login with the sent password) and applies the
   account check of item 1: another account, or a sign-in that does not
   verify, fails as in item 5 and nothing is written. So Fix Login also
   fails while the server cannot be reached, or while the profile active
   on the TV is held (no request goes to a held address) (Apple
   `5568737`, Android `9baa05f4`). Profiles, settings, and other
   playlists never change; a Fix Login screen takes only
   `playlist.credential` from whatever it receives. The progress line is
   "Signing in". Then the playlist's own rejected-key hold and its prompt
   are lifted (a profile's own held key stays held until that profile
   signs in as itself or its re-check passes; Apple `78cabaf`, Android
   `1198bfe2`), requests still built with the old key go out with the new
   one, the channels reload, and the screen shows "Signed in. Loading
   channels." for 2 seconds and closes.
5. No playlist here with that id, no sign-in in the payload, or a sent
   sign-in that is not the playlist's current account or cannot be
   verified (item 4): "Setup did not finish" with "The sign-in that was
   sent is not for a playlist on this device.", Retry (a new code), and
   Cancel; the screen stays open.

On the phone or tablet:

1. The Set up dock card and the Settings banner (same slot, one-row layout,
   sizing, and dismissal) show the device's name with the button "Fix
   Login" when its advert has `mode`=`fixlogin`, and only when this device
   has a Dispatcharr playlist whose id equals `pl`, or else, per the
   one-playlist identity rule, exactly one Dispatcharr playlist that signs
   in as the account sync reported for `pl`. That playlist must have a
   sign-in to send, and its own key must not be held as rejected here. The
   sender gate applies to that playlist (an Admin or Standard profile, or
   the default profile; never while the launch PIN is up). The device list in Set up another device
   lists setup receivers only.
2. Fix Login opens the sheet titled "Fix Login": the code, then the
   pre-send key check, then the sealed send. No scope, profile, or sync
   choices.
3. Payload: `mode`: `fixlogin` and `playlist` = that playlist with its
   `credential` (the playlist's own sign-in, as in a setup) and
   `playlist.id` = the advertised `pl`. No `profiles`, no `sync`.

   ```json
   {
     "mode": "fixlogin",
     "playlist": {
       "id": "6f1c2a4e-0b7d-4e52-9c1a-2d3e4f5a6b7c",
       "type": "dispatcharr",
       "name": "Home",
       "url": "https://server.example",
       "credential": { "apiKey": "...", "username": "..." }
     }
   }
   ```

   The other `playlist` fields are sent as in a setup (readers before Fix
   Login need `type`, `name`, and `url`); the receiver uses only `id` and
   `credential`.
4. Success: "Sent. <device name> is signing in."

## Security

- LAN only. No server path is used (setup, Fix Login, and the user QR
  display) and the server is never involved beyond the sender's existing
  pre-send key check; the README path tables are unchanged.
- The Fix Login advert's `pl` is a playlist id, not a secret; the sign-in
  itself travels only inside the sealed payload.
- One-time 6-digit code, 10 minute window, 3 attempts, then a new code and
  key pair. One successful send per code.
- End to end encrypted: the key needs both the receiver's public key (from the
  QR code or the TXT record) and the code. Passive listeners on the LAN
  see only ciphertext.
- Nothing is stored: the receiver's key pair and code live in memory for the
  session; the phone's key pair lives for one send.
- QR path: the QR code carries both the receiver's key and the code, so the
  sender is talking to the device on screen.
- List path: the TXT record carries no code material, so nothing on the
  LAN reveals the code. The code is verified only on the receiver, by decryption:
  a wrong code fails the AES-GCM tag and counts as one of the 3 attempts.
- Key fingerprint: 4 characters, the first 20 bits of SHA-256 over the
  receiver's 32-byte public key, encoded 5 bits at a time (most significant
  first) with the alphabet `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (no 0, 1, I,
  or O). The receiver shows it next to the code; the sender shows it for each
  listed device. A device advertising its own key under another device's name shows a
  different fingerprint, and without the code (shown only on the real device)
  it cannot decrypt a payload anyway.

## Show User QR Code

Phones and tablets show the active profile's Dispatcharr user code as the
same JSON QR the Dispatcharr web UI emits, so another device's "Scan QR
code" or "Choose from Photos" accepts it unchanged:

`{"v":1,"type":"user_api_key","api_key":"<key>","base_url":"<playlist url>","username":"<username>","first_name":"","last_name":"","email":""}`

- The button "Show User QR Code" sits after the other code
  buttons (Scan QR code, Choose from Photos, Import file) wherever they
  appear together: the Set up another device screen, Add Playlist, the
  Dispatcharr connect form, and Add Profile. The profile roster also
  offers it for the active profile, and an Admin or Standard profile may
  show it for any profile. It is hidden when the profile has no saved API key. TVs do not
  show it anywhere.
- Gate: when a Device Admin PIN or that profile's PIN exists, either one
  must be entered first ("Enter the PIN to show this code"); with no PIN
  set, the code shows directly.
- Screen "User QR Code": the code is blurred until tapped
  ("Tap to show"), hides again after 60 seconds or when the app leaves the
  foreground, and carries the caption "Anyone who scans this code can sign
  in as <username>. It hides after 60 seconds." Done closes it.
- Capture: Android sets FLAG_SECURE on that window. iOS cannot block
  screenshots; it blanks the code while the screen is recorded or shared
  ("Hidden while the screen is being recorded or shared.").
- The payload is never logged, copied to the clipboard, shared, or saved
  to Photos or files. It is built locally; no server path is used.

### Copy a setup from a user QR

When the device showing the code is on the same network, the scanner can
copy that device's whole setup instead of one user. The QR payload is
unchanged and no server path is used; everything stays on the LAN.

- Showing device ("source"), only while User QR Code is open with a code:
  listens on an ephemeral TCP port and advertises `_aeriotv-setup._tcp`
  (instance name = device name) with TXT `v`=1, `name`, `kind`
  (phone, tablet, or tv), `role`=`source`, and `uq` = lowercase hex of
  the first 8 bytes of SHA-256(UTF-8 of `aeriotv-userqr-v1:` + api_key).
  There is no `pk`, and sender discovery skips `role`=`source`.
- It serves `POST /user-qr` (HTTP/1.1, one request per connection,
  `Connection: close`). Body:
  `{"v":1,"link":"<scanner's aeriotv://setup link>","proof":"<base64 HMAC-SHA256(key = api_key, message = link)>"}`.
  Replies are `{"ok":true}` or `{"ok":false,"error":"<code>"}`: 413
  `too_large` (body over 8 KB), 403 `forbidden` (any Origin header, or a
  proof mismatch, compared in constant time), 404 `bad_request` (other
  path or method), 400 `bad_request` (unparseable, `v` not 1, or a link
  that does not parse), 409 `busy` (a request is already pending), 403
  `not_allowed` (the active profile cannot send a setup, a Child), 403
  `declined`, 502 `send_failed`, 200 on success.
- A valid request holds the connection while the showing device asks
  "Send setup to {name}?" ("This copies this device's playlist, profiles,
  and preferences to {name}.", Send / Don't send). Don't send, 120 seconds
  without an answer, or closing the screen replies `declined`. Send builds
  the same full payload as "Copy entire setup from this device" (every
  profile with a saved sign-in, sync on when Dispatcharr Sync is on there)
  and sends it to the link with the normal sealed `POST /setup`. Blur,
  PIN gate, 60 second hide, and capture blocking are unchanged.
- Scanning device (phones and tablets): after reading a user code it
  browses for up to 3 seconds ("Looking for the device showing this
  code") for `role`=`source` with a matching `uq`. Not found (a
  screenshot, the Dispatcharr web UI code, or another network) imports
  the user as before. Found: "Copy from {name}", subtitle "Copy every playlist and profile
  from {name}, or add just the user in this code.", with "Copy entire setup
  from this device" (default) or "Import this user only". Entire setup
  starts the normal receiver (advertised, as on Welcome, so other
  devices show the waiting banner), posts its link with the
  proof (150 second timeout), shows "Waiting for {name}", then applies the
  payload and continues to Add Profiles. A failure offers "Import this
  user only".

## Platform status

| Platform | Receiver | Sender |
|----------|----------|--------|
| Android TV | Done (`kind` = `tv`) | n/a |
| Android phone and tablet | Done (Welcome and Add Playlist) | Done (in-app scanner, Choose from Photos, Import file, and the system camera via the `aeriotv://setup` link; Show User QR Code) |
| Apple TV | Done (`kind` = `tv`) | n/a |
| iPhone and iPad | Done (Welcome and Add Playlist) | Done (in-app scanner, Choose from Photos, Import file, and the system camera via the `aeriotv://setup` link; Show User QR Code) |

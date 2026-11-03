# Set up another device

Wire format version 1. This file is identical in the Android repo
(`docs/DeviceSetupHandoff.md`) and the Apple repo
(`docs/DeviceSetupHandoff.md`). Change both in the same session.

## Why

Typing a server URL, an API key, and every profile's password with a TV
remote is the reason sync exists, yet a new TV still had to be typed into
once. With this flow any AerioTV device that already has the playlist sends
it, its profiles, and the sync choice to another device (TV, phone, or
tablet) over the local network.

## Roles

| Side | Who | What it does |
|------|-----|--------------|
| Receiver | Every device (Android TV, Apple TV, Android phone and tablet, iPhone, iPad) | Welcome > "Set up from another device", and on phones and tablets also Add Playlist > "Set up from another device". Generates a code and key pair, listens, advertises, shows a QR code and the code, applies the payload. |
| Sender | Phone or tablet (Android, iPhone, iPad) | Settings > Playlists > "Set up another device" (list and playlist detail; Admin or default profile only), a dock card directly above the tab bar while another device is advertising (that device's name and type icon, "Waiting for setup, key XXXX", Set up, and dismiss; it shares a row with the Control a TV button when that button shows), a banner at the top of the Settings root for the same device (same lines, Set up, and dismiss; one shared discovery, gating, and dismissal with the dock card), and "Set up another device with this playlist" on the phone onboarding's Add Profiles step. A device never lists its own advert. |

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
Choose from Photos, Import file, Show Dispatcharr User QR Code (see below). Import is manual only: AerioTV is not a share target and never
reads the clipboard.

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
    "type": "dispatcharr | xtream | m3u",
    "name": "Home",
    "url": "https://server.example",
    "xmltvUrl": null,
    "localUrl": "http://192.168.1.10:9191",
    "userAgent": null,
    "guideDays": 7,
    "catchupOffsetMinutes": 0,
    "vodEnabled": true,
    "channelProfileIds": [2],
    "credential": { "apiKey": "...", "username": "...", "password": "..." }
  },
  "profiles": [
    {
      "username": "alex",
      "displayName": "Alex",
      "role": "admin | user | child",
      "avatar": { "icon": "initial", "color": "" },
      "order": 0,
      "isDefault": true,
      "credential": null,
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

- `playlist.credential` is the playlist's own sign-in: the default
  profile's API key and/or username and password on Dispatcharr, the
  account login on Xtream Codes, absent on M3U. Only non-empty fields are
  sent.
- `guideDays` uses the stored Guide Days value (1 to 14, or 0 for All
  Available). `channelProfileIds` holds the playlist's Dispatcharr Channel
  Profile (empty = all channels).
- Profiles: `credential` is absent on the default profile and carries
  `apiKey` or `password` otherwise. PIN fields are the same v2 hash and
  salt Dispatcharr Sync carries in the `profiles` key; a PIN set before
  sync that has not been re-entered yet is sent as `none`.
- XC and M3U playlists send `playlist` only.
- `sync` is present only when the user chose to turn it on.

## Receiver apply

Non-interactive, with a progress line on screen:

1. "Connecting to your server": add the playlist through the normal Add
   Playlist save path (it loads the channels, which is the connection
   test), then store the catch-up offset. On failure: "Setup did not
   finish" with the error, Retry (re-applies the same payload), and Cancel.
2. "Adding profiles": the default profile first (name, role, avatar,
   order, PIN), then Admins, then the rest, each through the roster add
   path (signs in once with the sent credential, then applies role, PIN,
   avatar, display name, and order). A profile that fails is skipped and
   logged; the rest continue.
3. "Syncing": when `sync.enabled`, select Dispatcharr Sync (Google Drive
   sync goes off, as in Settings) and wait for the first pull.
4. Continue into the onboarding Add Profiles step (server user list,
   search, and QR import), so users whose credentials were not sent can be
   added exactly as in onboarding. Then finish onboarding, or return to
   Settings when the device was already set up, and open the main screen
   (the profile picker shows when the playlist asks for it).

## Security

- LAN only. No server path is used (setup and the user QR display) and the server is never involved; the
  README path tables are unchanged.
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

## Show Dispatcharr User QR Code

Phones and tablets show the active profile's Dispatcharr user code as the
same JSON QR the Dispatcharr web UI emits, so another device's "Scan QR
code" or "Choose from Photos" accepts it unchanged:

`{"v":1,"type":"user_api_key","api_key":"<key>","base_url":"<playlist url>","username":"<username>","first_name":"","last_name":"","email":""}`

- The button "Show Dispatcharr User QR Code" sits after the other code
  buttons (Scan QR code, Choose from Photos, Import file) wherever they
  appear together: the Set up another device screen, Add Playlist, the
  Dispatcharr connect form, and Add Profile. The profile roster also
  offers it for the active profile, and an Admin may show it for any
  profile. It is hidden when the profile has no saved API key. TVs do not
  show it anywhere.
- Gate: when a Device Admin PIN or that profile's PIN exists, either one
  must be entered first ("Enter the PIN to show this code"); with no PIN
  set, the code shows directly.
- Screen "Dispatcharr User QR Code": the code is blurred until tapped
  ("Tap to show"), hides again after 60 seconds or when the app leaves the
  foreground, and carries the caption "Anyone who scans this code can sign
  in as <username>. It hides after 60 seconds." Done closes it.
- Capture: Android sets FLAG_SECURE on that window. iOS cannot block
  screenshots; it blanks the code while the screen is recorded or shared
  ("Hidden while the screen is being recorded or shared.").
- The payload is never logged, copied to the clipboard, shared, or saved
  to Photos or files. It is built locally; no server path is used.

## Platform status

| Platform | Receiver | Sender |
|----------|----------|--------|
| Android TV | Done (`kind` = `tv`) | n/a |
| Android phone and tablet | Done (Welcome and Add Playlist) | Done (in-app scanner, Choose from Photos, Import file, a shared image, text, or file, and the system camera via the `aeriotv://setup` link; Show Dispatcharr User QR Code) |
| Apple TV | Done (`kind` = `tv`) | n/a |
| iPhone and iPad | Done (Welcome and Add Playlist) | Done (in-app scanner, Choose from Photos, Import file, and the system camera via the `aeriotv://setup` link; Show Dispatcharr User QR Code) |

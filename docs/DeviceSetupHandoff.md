# Set up a TV from your phone

Wire format version 1. This file is identical in the Android repo
(`docs/DeviceSetupHandoff.md`) and the Apple repo
(`docs/DeviceSetupHandoff.md`). Change both in the same session.

## Why

Typing a server URL, an API key, and every profile's password with a TV
remote is the reason sync exists, yet a new TV still had to be typed into
once. With this flow a phone or tablet that already has the playlist sends
it, its profiles, and the sync choice to the TV over the local network.

## Roles

| Side | Who | What it does |
|------|-----|--------------|
| Receiver | TV (Android TV, Apple TV) | Welcome > "Set up from your phone". Generates a code and key pair, listens, advertises, shows a QR code and the code, applies the payload. |
| Sender | Phone or tablet (Android, iPhone, iPad) | Settings > Playlists > "Set up a TV" (list and playlist detail; Admin or default profile only), a dock card directly above the tab bar while a TV is advertising (the TV name, "Waiting for setup, key XXXX", Set up, and dismiss; it shares a row with the Control a TV button when that button shows), a banner at the top of the Settings root for the same TV (same lines, Set up, and dismiss; one shared discovery, gating, and dismissal with the dock card), and "Set up a TV with this playlist" on the phone onboarding's Add Profiles step. |

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
   | `pk` | TV public key, 32 raw bytes, standard base64 with padding |

   The TXT record carries nothing derived from the code.
4. Show the QR code, the code in large type, next to it the key
   fingerprint as "Key XXXX" (see Security), the device name, and the line
   "Open AerioTV on your phone, then Settings > Playlists > open your
   playlist > Set up a TV, or scan this code."
5. The session lasts 10 minutes, then shows "The setup code expired" with
   New Code and Cancel. Cancel returns to Welcome. Leaving the screen stops
   the listener and the advert.

The companion remote host (`_aeriotv._tcp`) is a separate service and is
not involved.

## QR code and URL scheme

```
aeriotv://setup?v=1&ip=<lan ipv4>&port=<port>&code=<6 digits>&pk=<base64url pk>&name=<url-encoded name>
```

`pk` here is base64url without padding. Readers accept standard or URL-safe
base64, padded or not, for every key field. The QR is generated on the TV
(error correction H); no network call is made.

The sender registers the `aeriotv` scheme with host `setup`, so the system
camera opens AerioTV on the Set up a TV screen with the TV and code already
filled in. Android has no in-app camera scanner (the project carries no
camera or barcode dependency); the discovered TV list plus typing the code
is the fallback on every platform.

## Sender flow

1. Browse `_aeriotv-setup._tcp`; list each TV by `name` with the subtitle
   "Check that the TV shows XXXX", where XXXX is the key fingerprint
   computed from the advertised `pk`. Ignore adverts whose `v` is not `1` or whose `pk` is
   not 32 bytes.
2. Pick a TV, then enter the code shown on it. The sender does not check
   the code locally; only the TV verifies it, by decryption (a typo spends
   one of the TV's 3 attempts). A QR link skips this step.
3. Choose what to send:
   - The playlist, always.
   - Dispatcharr only: profiles, a checkbox per local profile of that
     playlist. The default profile is always sent (it signs in with the
     playlist login). The current profile is preselected. Each row says
     "API key saved", "Password saved", or that no sign-in is saved here
     (such a row cannot be sent).
   - Dispatcharr only: "Turn on Dispatcharr Sync on the TV", preselected
     when Dispatcharr Sync is on here.
4. Send. Results: sent ("The TV is finishing setup now"), wrong code (back
   to code entry), TV no longer waiting, or the TV could not be reached.

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
| 200 | `{"ok":true}` | Decrypted and accepted. The TV stops advertising and applies it. |
| 403 | `{"ok":false,"error":"wrong_code"}` | Decryption failed: the code (or key) does not match. |
| 403 | `{"ok":false,"error":"forbidden"}` | This code was already used, or the request carried `Origin`. |
| 400 | `{"ok":false,"error":"bad_request"}` | Not a version 1 envelope, bad base64, or bad payload JSON. Not counted as an attempt. |
| 413 | `{"ok":false,"error":"too_large"}` | Body over 256 KB. |

Code verification is the AEAD tag: the key depends on the code, so a
successful decrypt proves the phone used the code on screen. One success
per code; after 3 wrong-code failures the TV generates a new code and key
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
4. Finish onboarding and open the main screen (the profile picker shows
   when the playlist asks for it).

## Security

- LAN only. No server path is used and the server is never involved; the
  README path tables are unchanged.
- One-time 6-digit code, 10 minute window, 3 attempts, then a new code and
  key pair. One successful send per code.
- End to end encrypted: the key needs both the TV's public key (from the
  QR code or the TXT record) and the code. Passive listeners on the LAN
  see only ciphertext.
- Nothing is stored: the TV's key pair and code live in memory for the
  session; the phone's key pair lives for one send.
- QR path: the QR code carries both the TV's key and the code, so the phone
  is talking to the TV on screen.
- List path: the TXT record carries no code material, so nothing on the
  LAN reveals the code. The code is verified only on the TV, by decryption:
  a wrong code fails the AES-GCM tag and counts as one of the 3 attempts.
- Key fingerprint: 4 characters, the first 20 bits of SHA-256 over the
  TV's 32-byte public key, encoded 5 bits at a time (most significant
  first) with the alphabet `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (no 0, 1, I,
  or O). The TV shows it next to the code; the phone shows it for each
  listed TV. A device advertising its own key under a TV's name shows a
  different fingerprint, and without the code (shown only on the real TV)
  it cannot decrypt a payload anyway.

## Platform status

| Platform | Receiver | Sender |
|----------|----------|--------|
| Android TV | Done | n/a |
| Android phone and tablet | n/a | Done (QR via the system camera and the `aeriotv://setup` link) |
| Apple TV | Planned, same wire format | n/a |
| iPhone and iPad | n/a | Planned, same wire format |

# Third-party licenses

AerioTV for iOS, iPadOS, and tvOS is licensed under the GNU General Public
License v3.0 or later (see [LICENSE](LICENSE) and
[LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md)). This file lists the third-party
components it distributes or links, and the terms they carry.

The same information is available inside the app under
**Settings > About > Open Source Licenses**, together with the full text of each
license.

## MPVKit, mpv, and FFmpeg (LGPL-3.0-or-later)

AerioTV links [MPVKit](https://github.com/mpvkit/MPVKit), which packages the
[mpv](https://mpv.io) media player and its [FFmpeg](https://ffmpeg.org)
dependencies as an XCFramework for Apple platforms. It is the media engine that
plays live channels, video on demand, and recordings.

| | |
|---|---|
| Upstream | https://github.com/mpvkit/MPVKit |
| Version | MPVKit 1.0.0 (plain product, **not** `MPVKit-GPL`) |
| mpv | https://github.com/mpv-player/mpv |
| FFmpeg | https://ffmpeg.org |
| Modifications | None. Upstream binaries are used unmodified. |
| License | GNU Lesser General Public License, version 3 or later |

AerioTV links the plain `MPVKit` product, which is built **without**
`--enable-gpl`. The `-GPL` variant would add libsmbclient (the `smb://`
protocol) and unlock FFmpeg's GPL-only filters (yadif/bwdif deinterlace,
libpostproc); AerioTV uses none of those, links none of them, and the shipped
binary contains no such component. mpv and FFmpeg as bundled here are therefore
LGPL-3.0-or-later, which is GPL-compatible.

### Relinking

MPVKit is linked as a dynamic XCFramework, so it can be replaced with a modified
build, as section 4 of the LGPL requires. To do so: check out this project,
replace the MPVKit Swift Package dependency with your build of the same version
(or a compatible one), and rebuild the app in Xcode.

If you would rather receive the corresponding MPVKit / mpv / FFmpeg source
directly, open an issue at https://github.com/jonzey231/AerioTV/issues and it
will be provided.

## Google Cast SDK (proprietary)

`google-cast-sdk-no-bluetooth` (Google LLC) is used under the Google APIs Terms
of Service and the Google Cast SDK Additional Developer Terms of Service. It is
not open source. A GPL section 7 linking exception covering it is granted in
[LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md).

Upstream: https://developers.google.com/cast

## zlib License

**SwiftDraw** (Simon Whitty) — https://github.com/swhitty/SwiftDraw
Renders SVG channel logos and UI vector assets. Used under the zlib license
(see the package's LICENSE.txt).

## Protocol Buffers (BSD-3-Clause)

**SwiftProtobuf / Protobuf** (Google LLC) — https://github.com/apple/swift-protobuf
Pulled in transitively by the Google Cast SDK. Used under the 3-clause BSD
License.

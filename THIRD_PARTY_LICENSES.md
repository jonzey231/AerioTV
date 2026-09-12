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
| mpv | v0.41.0, https://github.com/mpv-player/mpv |
| FFmpeg | libavcodec 62.28.102 (FFmpeg 8.x), https://ffmpeg.org |
| Modifications | None. Upstream binaries are used unmodified. |
| License | GNU Lesser General Public License, version 3 or later |

AerioTV links the plain `MPVKit` product, which is built **without**
`--enable-gpl`. The `-GPL` variant would add libsmbclient (the `smb://`
protocol) and FFmpeg's GPL-only components such as libpostproc; AerioTV uses
none of those, links none of them, and the shipped binary contains no such
component. The deinterlace filters built into the shipped binary (`yadif`,
`bwdif`, `w3fdif`, `estdif`) are present in this LGPL build and are not
GPL-only; an earlier version of this file incorrectly described yadif and bwdif
as GPL-only. mpv and FFmpeg as bundled here are therefore LGPL-3.0-or-later,
which is GPL-compatible, and the shipped binaries self-report "LGPL version 3
or later".

### Relinking

MPVKit is linked as a dynamic XCFramework, so it can be replaced with a modified
build, as section 4 of the LGPL requires. To do so: check out this project,
replace the MPVKit Swift Package dependency with your build of the same version
(or a compatible one), and rebuild the app in Xcode.

If you would rather receive the corresponding MPVKit / mpv / FFmpeg source
directly, open an issue at https://github.com/jonzey231/AerioTV/issues and it
will be provided.

### MPVKit sub-libraries

MPVKit bundles the following libraries into the binaries AerioTV links. Each is
listed with its own terms in the app under **Settings > About > Open Source
Licenses**, together with the full text of its license.

| Component | Version | License |
|---|---|---|
| libass | 0.17.5 | ISC |
| FreeType | via libass-build 0.17.5 | FTL (FreeType License), dual licensed with GPL-2.0 |
| HarfBuzz | via libass-build 0.17.5 | MIT (Old MIT) |
| FriBidi | via libass-build 0.17.5 | LGPL-2.1-or-later |
| libunibreak | via libass-build 0.17.5 | zlib |
| OpenSSL | openssl-build 3.3.5 | Apache-2.0 |
| GnuTLS | gnutls-build 3.8.11 | LGPL-2.1-or-later |
| GMP | gnutls-build 3.8.11 | LGPL-3.0-or-later (dual with GPL-2.0-or-later) |
| Nettle | gnutls-build 3.8.11 | LGPL-3.0-or-later (dual with GPL-2.0-or-later) |
| Hogweed | gnutls-build 3.8.11 | LGPL-3.0-or-later (dual with GPL-2.0-or-later) |
| libplacebo | libplacebo-build 7.360.1 | LGPL-2.1-or-later |
| shaderc | libshaderc-build 2025.5.0 | Apache-2.0 |
| MoltenVK | moltenvk-build 1.4.2 | Apache-2.0 |
| Little CMS (lcms2) | lcms2-build 2.17.0 | MIT |
| libdovi | libdovi-build 3.3.2 | MIT |
| dav1d | libdav1d-build 1.5.3 | BSD-2-Clause |
| libuavs3d | libuavs3d-build 1.2.1 | BSD-3-Clause |
| libbluray | libbluray-build 1.4.0 | LGPL-2.1-or-later |
| libuchardet | libuchardet-build 0.0.8 | MPL-1.1 / GPL-2.0 / LGPL-2.1 (MPL-1.1 branch used) |

LuaJIT (MIT) is present in the MPVKit package manifest but is conditioned on
macOS, so it is not in the iOS, iPadOS, or tvOS binaries. libsmbclient
(GPL-3.0-or-later) is present in the manifest only under the `-GPL` product,
which AerioTV does not link.

For every LGPL sub-library above, the same relink route and source offer apply
as for MPVKit itself: the libraries ship as dynamic XCFrameworks and can be
replaced with a modified build, as section 4 of the LGPL v3 (section 6 of the
LGPL v2.1) requires. To receive the corresponding source directly, open an issue
at https://github.com/jonzey231/AerioTV/issues and it will be provided.

Source for the MPL-1.1 covered files in libuchardet is available upstream at
https://gitlab.freedesktop.org/uchardet/uchardet and can also be requested
through the same issue tracker.

### Apache-2.0 NOTICE

This product includes software developed by the OpenSSL Project for use in the
OpenSSL Toolkit (https://www.openssl.org/). OpenSSL 3.3.5 is used under the
Apache License, Version 2.0.

MoltenVK (The Brenwill Workshop Ltd. and the Khronos Group) and shaderc (The
Khronos Group) are used under the Apache License, Version 2.0. Full text:
https://www.apache.org/licenses/LICENSE-2.0

### FreeType credit

Portions of this software are copyright (C) 2026 The FreeType Project
(www.freetype.org). All rights reserved.

## Google Cast SDK (proprietary)

`google-cast-sdk-no-bluetooth` (Google LLC) is used under the Google APIs Terms
of Service and the Google Cast SDK Additional Developer Terms of Service. It is
not open source. A GPL section 7 linking exception covering it is granted in
[LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md).

Upstream: https://developers.google.com/cast

## zlib License

**SwiftDraw** 0.29.0 (Simon Whitty), https://github.com/swhitty/SwiftDraw
Renders SVG channel logos and UI vector assets. Used under the zlib license
(see the package's LICENSE.txt).

## Protocol Buffers (BSD-3-Clause)

**Protobuf** 3.29.6, Google's Objective-C Protocol Buffers runtime (Google LLC),
https://github.com/protocolbuffers/protobuf
Pulled in transitively by the Google Cast SDK as the CocoaPod `Protobuf`. Used
under the 3-clause BSD License. This is not `apple/swift-protobuf`.

## TMDB

This product uses the TMDB API but is not endorsed or certified by TMDB.

Artwork and metadata are retrieved from https://www.themoviedb.org under the
TMDB API Terms of Use. The TMDB logo is used per
https://www.themoviedb.org/about/logos-attribution.

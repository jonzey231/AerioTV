//
//  TSHLSPlaylist.swift
//  Aerio
//
//  Media playlist text for TSHLSRemuxer (loopback, LAN and in-process
//  copies). Pulled out of the remuxer on 2026-09-27 for the seamless
//  AirPlay channel flip: the flip splices a new channel into the SAME
//  playlist (EXT-X-DISCONTINUITY on the new source's first segment, media
//  sequence continuing), and that splice has to be testable off-device.
//
//  Pure logic, no app singletons, so Scripts/cast-hls-proxy-tests
//  compiles it as is.
//

import Foundation

enum TSHLSPlaylist {

    /// One listed segment: its sequence number, EXTINF duration and URI.
    struct Entry: Equatable {
        let seq: Int
        let duration: Double
        let uri: String
    }

    /// The playlist served before any segment exists.
    static func emptyText(targetDuration: Int) -> String {
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(targetDuration)\n#EXT-X-MEDIA-SEQUENCE:0\n"
    }

    /// EXT-X-DISCONTINUITY-SEQUENCE of a window starting at `firstSeq`: the
    /// count of tagged segments that already slid out ahead of it. Every
    /// window variant (live RAM, Live Rewind spill, inlined, event, LAN)
    /// derives it from the same tagged-seq set, so the value stays
    /// consistent across reloads and across variants (RFC 8216 6.2.2).
    static func discontinuitySequence(firstSeq: Int, discontinuitySeqs: Set<Int>) -> Int {
        discontinuitySeqs.filter { $0 < firstSeq }.count
    }

    /// The media playlist for `window` (non-empty, ascending seq).
    /// `mapURI` is the EXT-X-MAP URI of the fMP4 arm (nil on the TS arm).
    static func render(window: [Entry], targetDuration: Int, version: Int,
                       discontinuitySeqs: Set<Int>, eventPlaylist: Bool,
                       mapURI: String?, complete: Bool) -> String {
        guard let first = window.first else { return emptyText(targetDuration: targetDuration) }
        var text = "#EXTM3U\n#EXT-X-VERSION:\(version)\n#EXT-X-TARGETDURATION:\(targetDuration)\n"
            + "#EXT-X-MEDIA-SEQUENCE:\(first.seq)\n"
        // Only written once a discontinuity exists, so a session that
        // never flipped serves byte-identical playlists to before.
        if !discontinuitySeqs.isEmpty {
            text += "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence(firstSeq: first.seq, discontinuitySeqs: discontinuitySeqs))\n"
        }
        if eventPlaylist {
            text += "#EXT-X-PLAYLIST-TYPE:EVENT\n"
        }
        if let mapURI {
            text += "#EXT-X-MAP:URI=\"\(mapURI)\"\n"
        }
        for segment in window {
            if discontinuitySeqs.contains(segment.seq) {
                text += "#EXT-X-DISCONTINUITY\n"
            }
            text += "#EXTINF:\(String(format: "%.3f", segment.duration)),\n"
            text += "\(segment.uri)\n"
        }
        if complete {
            text += "#EXT-X-ENDLIST\n"
        }
        return text
    }

    /// True once a receiver fetched a segment of the generation that
    /// starts at `generationFirstSeq` (the flip's discontinuity seq).
    /// `receiverHighestSeq` is -1 until the receiver fetched anything.
    static func receiverCrossed(receiverHighestSeq: Int, generationFirstSeq: Int) -> Bool {
        receiverHighestSeq >= 0 && receiverHighestSeq >= generationFirstSeq
    }
}

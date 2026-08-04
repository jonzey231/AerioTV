import UIKit
#if canImport(SwiftDraw)
import SwiftDraw
#endif

// GH #61: SVG channel logo support. A lot of IPTV playlists point
// tvg-logo (and some poster fields) at .svg assets, which
// `UIImage(data:)` cannot decode - those channels rendered the
// placeholder monogram forever. Every logo/poster byte load now runs
// through this helper: bitmap formats keep the exact old path, and
// anything that sniffs as SVG is rasterized once via SwiftDraw and
// then cached by the caller like any other UIImage.
enum AerioImageDecoding {

    /// Decode image bytes into a UIImage, accepting SVG in addition to
    /// the bitmap formats UIKit handles natively.
    ///
    /// - `maxDimension` caps the rasterized SVG size. Logos render at
    ///   list-row sizes (well under 512pt even on tvOS), and SVGs with
    ///   huge or missing intrinsic sizes must not allocate a giant
    ///   bitmap. Bitmaps are returned untouched - existing callers
    ///   already display them at fitted sizes.
    static func decode(_ data: Data, maxDimension: CGFloat = 512) -> UIImage? {
        if let bitmap = UIImage(data: data) {
            return bitmap
        }
        guard looksLikeSVG(data) else { return nil }
        return rasterizeSVG(data, maxDimension: maxDimension)
    }

    /// Content sniff, not extension: many playlist logo URLs have no
    /// path extension at all. An SVG is XML text, so after optional
    /// BOM/whitespace it starts with "<?xml", "<svg", or a comment/
    /// doctype that still contains "<svg" early on.
    static func looksLikeSVG(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        // SVGs are small text files; anything huge is not a logo we
        // want to rasterize on a UI-adjacent path.
        guard data.count <= 2_000_000 else { return false }
        // Strip a BOM explicitly. `.whitespacesAndNewlines` does NOT
        // include U+FEFF (it is category Cf, not Z), so a byte-order
        // mark survived the trim and every hasPrefix check below failed
        // -- a BOM'd SVG (routine output from Windows/.NET tooling and
        // some CDNs) was rejected and fell back to the placeholder
        // monogram, which is the exact symptom GH #61 reported.
        let head = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .lowercased()
        guard head.hasPrefix("<?xml") || head.hasPrefix("<svg") ||
              head.hasPrefix("<!doctype svg") || head.hasPrefix("<!--")
        else { return false }
        // "<?xml" alone could be XMLTV or any other XML; require the
        // svg root tag somewhere in the head window.
        return head.contains("<svg")
    }

    private static func rasterizeSVG(_ data: Data, maxDimension: CGFloat) -> UIImage? {
        #if canImport(SwiftDraw)
        guard let svg = SwiftDraw.SVG(data: data) else { return nil }
        var size = svg.size
        // Guard degenerate intrinsic sizes (0 or absent viewBox) and
        // scale oversized ones down preserving aspect.
        if size.width <= 1 || size.height <= 1 {
            size = CGSize(width: 256, height: 256)
        }
        let longest = max(size.width, size.height)
        if longest > maxDimension {
            let scale = maxDimension / longest
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        return svg.rasterize(size: size)
        #else
        return nil
        #endif
    }
}

#if DEBUG
import Foundation

/// Fixture-driven drift detection for the personal-media-library contract.
///
/// The design calls for "fixture-JSON decode tests so API drift surfaces as one
/// failing test file". This project has no unit-test target (only a UI-test
/// bundle, which cannot see app types), so the equivalent lives here as a
/// DEBUG-only self-check that runs once at launch and logs loudly. It costs
/// nothing in release builds and gives the same signal: if Dispatcharr renames
/// a key or changes the marker shape, this reports it in one place instead of
/// letting personal libraries silently degrade into provider catalogs.
///
/// The fixtures are hand-written to match the pre-merge branch's shapes. When
/// the branch merges, re-capture them from a real server and re-run.
enum MediaLibraryFixtures {

    /// A provider relation as written by the media-server import.
    static let personalRelationJSON = """
    {
      "managed_source": "media_server",
      "provider": "local",
      "integration_id": 3,
      "integration_name": "Basement NAS",
      "provider_library": "Movies"
    }
    """

    /// The same field on a stock server: absent entirely.
    static let stockRelationJSON = "{}"

    /// Runs every check, logging each failure. Returns true when all pass.
    @discardableResult
    static func runSelfCheck() -> Bool {
        var failures: [String] = []

        // 1. The marker decodes and identifies personal-library content.
        if let data = personalRelationJSON.data(using: .utf8) {
            do {
                let marker = try JSONDecoder().decode(DispatcharrMediaLibraryAdapter.ProviderMarker.self, from: data)
                if !marker.isPersonalLibrary {
                    failures.append("managed_source marker did not read as personal library")
                }
                if marker.integrationName != "Basement NAS" {
                    failures.append("integration_name did not decode")
                }
            } catch {
                failures.append("personal relation failed to decode: \(error)")
            }
        }

        // 2. A stock server's empty object decodes and reads as NOT personal.
        if let data = stockRelationJSON.data(using: .utf8) {
            do {
                let marker = try JSONDecoder().decode(DispatcharrMediaLibraryAdapter.ProviderMarker.self, from: data)
                if marker.isPersonalLibrary {
                    failures.append("empty relation wrongly read as personal library")
                }
            } catch {
                failures.append("stock relation failed to decode (must be tolerant): \(error)")
            }
        }

        // 3. Category namespace parsing, including a library name that itself
        //    contains the delimiter (split on the FIRST one only).
        let lib = LibraryDeriver.parse(categoryName: "Basement NAS - Kids - Bedtime",
                                       categoryType: "movie",
                                       serverID: "S1",
                                       isPersonal: true)
        if lib.sourceName != "Basement NAS" || lib.libraryName != "Kids - Bedtime" {
            failures.append("category namespace split wrong: \(lib.sourceName) / \(lib.libraryName)")
        }

        // 4. A provider catalog category is NOT split, even when it has a dash.
        let provider = LibraryDeriver.parse(categoryName: "Action - Thriller",
                                            categoryType: "movie",
                                            serverID: "S1",
                                            isPersonal: false)
        if provider.isPersonal || provider.libraryName != "Action - Thriller" {
            failures.append("provider category was wrongly namespaced")
        }

        // 5. Poster policy: cache_url wins, and a filesystem path is REFUSED.
        //    This is the check that matters most; requesting logo.url for a
        //    media-library item asks for a path on the server's disk.
        let base = URL(string: "https://example.test")
        let cached = DispatcharrMediaLibraryAdapter.posterURL(
            cacheURL: "/api/vod/vodlogos/12/cache/",
            url: "/data/media/Movies/Example/poster.jpg",
            serverBaseURL: base)
        if cached?.absoluteString != "https://example.test/api/vod/vodlogos/12/cache/" {
            failures.append("cache_url did not resolve against the server base: \(String(describing: cached))")
        }
        let filesystemOnly = DispatcharrMediaLibraryAdapter.posterURL(
            cacheURL: nil,
            url: "/data/media/Movies/Example/poster.jpg",
            serverBaseURL: base)
        if filesystemOnly != nil {
            failures.append("a filesystem path was accepted as a poster URL")
        }
        let ordinary = DispatcharrMediaLibraryAdapter.posterURL(
            cacheURL: nil,
            url: "https://images.example.test/poster.jpg",
            serverBaseURL: base)
        if ordinary == nil {
            failures.append("an ordinary absolute poster URL was rejected")
        }

        // 6. Sort titles: articles stripped, buckets correct.
        if MediaSortTitle.make(from: "The Matrix") != "matrix" {
            failures.append("leading article not stripped from sort title")
        }
        if MediaSortTitle.bucket(for: MediaSortTitle.make(from: "2001: A Space Odyssey")) != "#" {
            failures.append("numeric title did not bucket under #")
        }

        if failures.isEmpty {
            debugLog("[MediaLibraryFixtures] contract self-check passed")
            return true
        }
        for f in failures {
            debugLog("[MediaLibraryFixtures] FAILED: \(f)")
        }
        assertionFailure("Media library contract drift: \(failures.joined(separator: "; "))")
        return false
    }
}
#endif

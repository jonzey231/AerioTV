import Foundation

/// EVERY assumption about Dispatcharr's personal-media-library support lives in
/// this one file, so that server-side drift shows up as a failing fixture test
/// here instead of scattered breakage across the Movies & TV UI.
///
/// What the server actually provides (verified against the pre-merge branch):
/// imported personal media is written into the SAME `/api/vod/` models a
/// provider catalog uses. There is no content API of its own, no library
/// endpoint a normal user may read, no seasons model, no cast, no server-side
/// watch state. Two things distinguish a personal-library item:
///
///  1. the provider relation carries `custom_properties.managed_source ==
///     "media_server"` (plus provider / integration_name / provider_library),
///  2. its category is namespaced "{source name} - {library name}".
///
/// Neither exists on a stock server, and both are additive JSON, so absence is
/// the normal case and simply reads as a provider catalog.
enum DispatcharrMediaLibraryAdapter {

    /// The marker value the import layer writes into the provider relation.
    static let managedSourceMarker = "media_server"

    /// The subset of a provider relation's `custom_properties` this app reads.
    /// Everything is optional: old servers omit the whole object.
    struct ProviderMarker: Decodable, Equatable {
        let managedSource: String?
        /// Which kind of media server produced this item. Recorded for
        /// diagnostics ONLY: it must never reach user-facing copy.
        let provider: String?
        let integrationID: Int?
        /// The user's own name for their source; preferred over the parsed
        /// category prefix when present.
        let integrationName: String?
        let providerLibrary: String?

        enum CodingKeys: String, CodingKey {
            case managedSource = "managed_source"
            case provider
            case integrationID = "integration_id"
            case integrationName = "integration_name"
            case providerLibrary = "provider_library"
        }

        var isPersonalLibrary: Bool { managedSource == managedSourceMarker }
    }

    /// True when this relation marks personal-library content.
    static func isPersonalLibrary(_ marker: ProviderMarker?) -> Bool {
        marker?.isPersonalLibrary ?? false
    }

    // MARK: - Poster policy

    /// Resolve the poster URL for a VOD item's logo.
    ///
    /// This is the single most dangerous field in the integration. For
    /// media-library items `logo.url` is a path on the SERVER'S FILESYSTEM
    /// (for example `/data/media/Movies/Dune/poster.jpg`), which is useless and
    /// would render as a broken image or, worse, be handed to an image loader
    /// as a local path. `logo.cache_url` (`/api/vod/vodlogos/{id}/cache/`,
    /// AllowAny) is the only correct source for those, and it also works fine
    /// for ordinary provider VOD.
    ///
    /// Policy: prefer cache_url; fall back to url ONLY when it is an absolute
    /// http(s) URL. A filesystem path yields nil so the UI shows its placeholder.
    static func posterURL(cacheURL: String?, url: String?, serverBaseURL: URL?) -> URL? {
        if let cacheURL, !cacheURL.isEmpty {
            if let absolute = URL(string: cacheURL), absolute.scheme != nil {
                return absolute
            }
            // Relative path form ("/api/vod/vodlogos/12/cache/"): resolve
            // against the server we fetched it from.
            if let base = serverBaseURL, let resolved = URL(string: cacheURL, relativeTo: base) {
                return resolved.absoluteURL
            }
        }
        guard let url, !url.isEmpty, let candidate = URL(string: url),
              let scheme = candidate.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return candidate
    }

    // MARK: - Library derivation

    /// Category name -> library facets, using the relation marker when present.
    static func library(forCategoryNamed name: String,
                        categoryType: String,
                        serverID: String,
                        marker: ProviderMarker?) -> LibraryDeriver.Library {
        LibraryDeriver.parse(categoryName: name,
                             categoryType: categoryType,
                             serverID: serverID,
                             isPersonal: isPersonalLibrary(marker),
                             integrationName: marker?.integrationName)
    }
}

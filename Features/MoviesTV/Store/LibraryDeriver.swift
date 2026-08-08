import Foundation

/// Derives the Libraries list CLIENT-SIDE, because the server has no library
/// API a normal user may read.
///
/// Dispatcharr's media-server import writes personal-library content into the
/// same VOD models a provider catalog uses, namespacing the categories as
/// "{source name} - {library name}" (category_type movie or series). The
/// `/api/media-library/` REST surface that would name sources directly is
/// admin-only, so category-name parsing is the only signal available to the
/// app. When the marker is absent (stock Dispatcharr, or a pre-merge server),
/// everything simply reads as a provider catalog and nothing breaks.
///
/// User-facing copy uses the source's own user-assigned name; it never names a
/// third-party media-server product.
enum LibraryDeriver {

    struct Library: Hashable, Identifiable {
        /// Stable key stored on catalog rows: "{serverID}|{categoryName}".
        let key: String
        /// The user's own name for the source that owns this library.
        let sourceName: String
        /// The library's name within that source.
        let libraryName: String
        /// "movie" or "series".
        let mediaType: String
        let isPersonal: Bool

        var id: String { key }

        /// Row header / scope chip label.
        var displayName: String {
            sourceName.isEmpty ? libraryName : "\(sourceName): \(libraryName)"
        }
    }

    /// The namespace delimiter the import layer writes.
    private static let delimiter = " - "

    /// Split "{source} - {library}" on the FIRST delimiter only: library names
    /// routinely contain a dash ("Kids - Bedtime"), source names much less so,
    /// and the import writes source first.
    static func parse(categoryName: String,
                      categoryType: String,
                      serverID: String,
                      isPersonal: Bool,
                      integrationName: String? = nil) -> Library {
        let key = "\(serverID)|\(categoryName)"
        guard isPersonal, let range = categoryName.range(of: delimiter) else {
            // Provider catalog: the category IS the library, with no source.
            return Library(key: key, sourceName: "", libraryName: categoryName,
                           mediaType: categoryType, isPersonal: false)
        }
        var source = String(categoryName[categoryName.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let library = String(categoryName[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)

        // When the provider relation carried an integration_name, prefer it:
        // it is the user's actual source name, unmangled by any delimiter the
        // library name may also contain.
        if let integrationName, !integrationName.isEmpty {
            source = integrationName
        }
        return Library(key: key, sourceName: source, libraryName: library,
                       mediaType: categoryType, isPersonal: true)
    }

    /// Sort order for Home rows and scope chips: personal libraries first
    /// (the tab is a personal-library experience), then provider catalogs,
    /// each alphabetical by display name.
    static func ordered(_ libraries: [Library]) -> [Library] {
        libraries.sorted { lhs, rhs in
            if lhs.isPersonal != rhs.isPersonal { return lhs.isPersonal }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

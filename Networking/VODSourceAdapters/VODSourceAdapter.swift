import Foundation

/// One way in for every VOD source the catalog can ingest.
///
/// The adapters deliberately return the app's EXISTING display models
/// (`VODMovie` / `VODSeries` / `VODCategory`) rather than a new wire type:
/// those structs are already the UI's vocabulary everywhere, and the catalog's
/// job is to persist them, not to redefine them. That keeps detail and playback
/// code completely untouched by this phase.
protocol VODSourceAdapter {
    /// Server-visible label for logs and diagnostics.
    var sourceKind: String { get }

    func fetchMovies(from server: ServerSnapshot) async throws -> ([VODMovie], [VODCategory])
    func fetchSeries(from server: ServerSnapshot) async throws -> ([VODSeries], [VODCategory])
}

/// Dispatcharr. Personal-library facets are layered on by
/// `DispatcharrMediaLibraryAdapter`; everything else is the long-standing
/// `VODService` path, unchanged.
struct DispatcharrVODAdapter: VODSourceAdapter {
    let sourceKind = "dispatcharr"

    func fetchMovies(from server: ServerSnapshot) async throws -> ([VODMovie], [VODCategory]) {
        try await VODService.fetchMovies(from: server)
    }

    func fetchSeries(from server: ServerSnapshot) async throws -> ([VODSeries], [VODCategory]) {
        try await VODService.fetchSeries(from: server)
    }
}

/// Xtream Codes panels. No created_at anywhere in the protocol, so the catalog
/// treats these as full-resweep sources (see CatalogIngestActor).
struct XtreamVODAdapter: VODSourceAdapter {
    let sourceKind = "xtream"

    func fetchMovies(from server: ServerSnapshot) async throws -> ([VODMovie], [VODCategory]) {
        try await VODService.fetchMovies(from: server)
    }

    func fetchSeries(from server: ServerSnapshot) async throws -> ([VODSeries], [VODCategory]) {
        try await VODService.fetchSeries(from: server)
    }
}

enum VODSourceAdapterFactory {
    /// M3U playlists carry no VOD catalog, so they get no adapter at all.
    static func adapter(for server: ServerSnapshot) -> VODSourceAdapter? {
        switch server.type {
        case .dispatcharrAPI: return DispatcharrVODAdapter()
        case .xtreamCodes:    return XtreamVODAdapter()
        case .m3uPlaylist:    return nil
        }
    }
}

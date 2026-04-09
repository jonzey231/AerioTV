@preconcurrency import TVServices
import Security
import os.log

/// Top Shelf content provider — shows Continue Watching VOD (poster art)
/// and Top Channels (hdtv logo cards) by reading data from a **shared
/// keychain item** written by the main Aerio app.
///
/// Keychain access group `47DTJ3Q67T.aerio.topshelf.shared` is covered by
/// the wildcard `47DTJ3Q67T.*` keychain-access-groups entitlement already
/// granted by the provisioning profile, so no portal changes are needed.
///
/// Image URLs are passed straight through from the source data — we tried
/// pre-processing them into aspect-fit padded files locally (both in the
/// extension's Caches dir and the main app's Caches dir) and conclusively
/// proved that tvOS's Top Shelf host process (PineBoard) cannot read from
/// either sandbox. Apple's docs explicitly recommend storing images in the
/// extension's *bundle*, but bundles are sealed at build time and cannot
/// hold dynamic per-user data like IPTV channel logos that depend on which
/// server a user configures at runtime. So we rely on tvOS's built-in
/// remote URL loading and accept its native scaling behavior.
class ContentProvider: TVTopShelfContentProvider {

    private let log = OSLog(subsystem: "app.molinete.aerio.topshelf", category: "ContentProvider")

    // MARK: - Keychain

    private static let kcService = "aerio.topshelf"
    private static let kcAccessGroup = "47DTJ3Q67T.aerio.topshelf.shared"

    private func readArray(key: String) -> [[String: String]]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.kcService,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Self.kcAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            return arr
        }
        if status != errSecItemNotFound {
            os_log("❌ Keychain read failed key=%{public}@ status=%d",
                   log: log, type: .error, key, status)
        }
        return nil
    }

    // MARK: - Load content

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        os_log("loadTopShelfContent called", log: log, type: .default)

        let vodEntries = readArray(key: "continueWatching") ?? []
        let channelEntries = readArray(key: "topChannels") ?? []

        os_log("📺 continueWatching: %d entries, topChannels: %d entries",
               log: log, type: .default, vodEntries.count, channelEntries.count)

        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        // ── Top Channels first (hdtv 16:9 cards — more forgiving than
        //    `.square` or `.poster` for typical IPTV channel logos which
        //    vary wildly in aspect ratio) ──
        if !channelEntries.isEmpty {
            let items = channelEntries.compactMap { entry -> TVTopShelfSectionedItem? in
                guard let id = entry["id"], let name = entry["name"] else { return nil }
                guard let logoStr = entry["logoURL"],
                      let logoURL = URL(string: logoStr) else { return nil }

                let item = TVTopShelfSectionedItem(identifier: "channel-\(id)")
                if let program = entry["currentProgram"], !program.isEmpty {
                    item.title = "\(name) — \(program)"
                } else {
                    item.title = name
                }
                item.imageShape = .hdtv
                item.setImageURL(logoURL, for: .screenScale1x)
                item.setImageURL(logoURL, for: .screenScale2x)

                if let deepLink = URL(string: "aerio://channel/\(id)") {
                    item.playAction = TVTopShelfAction(url: deepLink)
                    item.displayAction = TVTopShelfAction(url: deepLink)
                }
                return item
            }
            if !items.isEmpty {
                let section = TVTopShelfItemCollection(items: items)
                section.title = "Top Channels"
                sections.append(section)
            }
        }

        // ── Continue Watching (VOD posters, 2:3 aspect) ──
        if !vodEntries.isEmpty {
            let items = vodEntries.compactMap { entry -> TVTopShelfSectionedItem? in
                guard let vodID = entry["vodID"], let title = entry["title"] else { return nil }
                guard let posterStr = entry["posterURL"],
                      let posterURL = URL(string: posterStr) else { return nil }

                let item = TVTopShelfSectionedItem(identifier: "vod-\(vodID)")
                if let posMs = Int(entry["positionMs"] ?? ""),
                   let durMs = Int(entry["durationMs"] ?? ""),
                   durMs > 0 {
                    let percent = Int(Double(posMs) / Double(durMs) * 100)
                    item.title = "\(title) • \(percent)%"
                } else {
                    item.title = title
                }
                item.imageShape = .poster
                item.setImageURL(posterURL, for: .screenScale1x)
                item.setImageURL(posterURL, for: .screenScale2x)

                // Build a deep link that targets a navigable destination:
                //   movie  → aerio://vod/movie/<movieID>
                //   episode → aerio://vod/series/<seriesID>  (navigates to
                //             the parent series detail, since episodes have
                //             no standalone detail view of their own)
                let vodType = entry["vodType"] ?? "movie"
                let deepLinkURL: URL? = {
                    if vodType == "episode", let seriesID = entry["seriesID"] {
                        return URL(string: "aerio://vod/series/\(seriesID)")
                    }
                    return URL(string: "aerio://vod/\(vodType)/\(vodID)")
                }()
                if let deepLink = deepLinkURL {
                    item.playAction = TVTopShelfAction(url: deepLink)
                    item.displayAction = TVTopShelfAction(url: deepLink)
                }
                return item
            }
            if !items.isEmpty {
                let section = TVTopShelfItemCollection(items: items)
                section.title = "Continue Watching"
                sections.append(section)
            }
        }

        os_log("Returning %d sections", log: log, type: .default, sections.count)
        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }
}

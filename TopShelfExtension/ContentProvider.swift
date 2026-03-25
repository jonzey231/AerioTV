import TVServices

class ContentProvider: TVTopShelfContentProvider {

    private static let appGroupID = "group.app.molinete.Dispatcharr"

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        guard let shared = UserDefaults(suiteName: Self.appGroupID),
              let entries = shared.array(forKey: "topShelfFavorites") as? [[String: String]],
              !entries.isEmpty else {
            return nil
        }

        var items: [TVTopShelfSectionedItem] = []
        for entry in entries {
            guard let id = entry["id"], let name = entry["name"] else { continue }

            let item = TVTopShelfSectionedItem(identifier: id)
            item.title = name

            // Channel logo
            if let logoStr = entry["logoURL"], let logoURL = URL(string: logoStr) {
                item.setImageURL(logoURL, for: .screenScale1x)
                item.setImageURL(logoURL, for: .screenScale2x)
            }

            // Deep link to play this channel
            if let deepLink = URL(string: "aerio://channel/\(id)") {
                item.playAction = TVTopShelfAction(url: deepLink)
                item.displayAction = TVTopShelfAction(url: deepLink)
            }

            items.append(item)
        }

        let section = TVTopShelfItemCollection(items: items)
        section.title = "Favorite Channels"

        return TVTopShelfSectionedContent(sections: [section])
    }
}

import TVServices

class ContentProvider: TVTopShelfContentProvider {

    private static let appGroupID = "group.app.molinete.Dispatcharr"

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        guard let shared = UserDefaults(suiteName: Self.appGroupID),
              let entries = shared.array(forKey: "topShelfChannels") as? [[String: String]],
              !entries.isEmpty else {
            // No watch history yet — show a single welcome item
            let welcome = TVTopShelfSectionedItem(identifier: "welcome")
            welcome.title = "Start watching to see your top channels here"
            if let launch = URL(string: "aerio://launch") {
                welcome.displayAction = TVTopShelfAction(url: launch)
            }
            let section = TVTopShelfItemCollection(items: [welcome])
            section.title = "Aerio"
            return TVTopShelfSectionedContent(sections: [section])
        }

        var items: [TVTopShelfSectionedItem] = []
        for entry in entries {
            guard let id = entry["id"], let name = entry["name"] else { continue }

            let item = TVTopShelfSectionedItem(identifier: id)
            // Show channel name + current program
            if let program = entry["currentProgram"], !program.isEmpty {
                item.title = name
                item.subtitle = program  // What's currently airing
            } else {
                item.title = name
            }

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
        section.title = "Most Watched"

        return TVTopShelfSectionedContent(sections: [section])
    }
}

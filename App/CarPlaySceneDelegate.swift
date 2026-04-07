#if canImport(CarPlay)
import CarPlay
import UIKit

/// CarPlay scene delegate — provides audio-only channel browsing via CarPlay templates.
/// Channels are read from the shared `ChannelStore`; playback is triggered via `NowPlayingManager`.
/// All shared state access dispatches to the main thread to avoid data races.
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    // MARK: - Scene Lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let tabBar = buildTabBar()
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Tab Bar

    private func buildTabBar() -> CPTabBarTemplate {
        let favoritesTab = buildFavoritesTemplate()
        let groupsTab = buildGroupsTemplate()
        let nowPlayingTab = CPNowPlayingTemplate.shared

        let tabBar = CPTabBarTemplate(templates: [favoritesTab, groupsTab, nowPlayingTab])
        return tabBar
    }

    // MARK: - Favorites Tab

    private func buildFavoritesTemplate() -> CPListTemplate {
        let items: [ChannelDisplayItem] = DispatchQueue.main.sync {
            FavoritesStore.shared.favoriteItems
        }

        let listItems = items.map { makeChannelItem($0) }
        let section = CPListSection(items: listItems)
        let template = CPListTemplate(title: "Favorites", sections: [section])
        template.tabSystemItem = .favorites
        template.emptyViewTitleVariants = ["No Favorites"]
        template.emptyViewSubtitleVariants = ["Star channels in the app to see them here"]
        return template
    }

    // MARK: - Groups Tab

    private func buildGroupsTemplate() -> CPListTemplate {
        let (groups, channels): ([String], [ChannelDisplayItem]) = DispatchQueue.main.sync {
            (ChannelStore.shared.orderedGroups, ChannelStore.shared.channels)
        }

        let groupItems: [CPListItem] = groups.map { groupName in
            let count = channels.filter { $0.group == groupName }.count
            let item = CPListItem(
                text: groupName,
                detailText: "\(count) channel\(count == 1 ? "" : "s")"
            )
            item.handler = { [weak self] _, completion in
                self?.showChannelsInGroup(groupName, allChannels: channels)
                completion()
            }
            item.accessoryType = .disclosureIndicator
            return item
        }

        let section = CPListSection(items: groupItems)
        let template = CPListTemplate(title: "Groups", sections: [section])
        template.tabSystemItem = .more
        template.emptyViewTitleVariants = ["No Channels"]
        template.emptyViewSubtitleVariants = ["Add a server in the app first"]
        return template
    }

    /// Push a channel list for a specific group.
    private func showChannelsInGroup(_ group: String, allChannels: [ChannelDisplayItem]) {
        let channels = allChannels.filter { $0.group == group }
        let listItems = channels.map { makeChannelItem($0) }
        let section = CPListSection(items: listItems)
        let template = CPListTemplate(title: group, sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Channel Item Factory

    private func makeChannelItem(_ channel: ChannelDisplayItem) -> CPListItem {
        let detail = channel.currentProgram ?? channel.group
        let item = CPListItem(text: channel.name, detailText: detail)

        // Load channel logo asynchronously
        if let logoURL = channel.logoURL {
            Task {
                guard !Task.isCancelled else { return }
                if let (data, _) = try? await URLSession.shared.data(from: logoURL),
                   let image = UIImage(data: data) {
                    guard !Task.isCancelled else { return }
                    let maxSize = CPListItem.maximumImageSize
                    let scaled = image.scaledToFit(maxSize)
                    await MainActor.run {
                        item.setImage(scaled)
                    }
                }
            }
        }

        item.handler = { [weak self] _, completion in
            self?.playChannel(channel)
            completion()
        }

        // Show now-playing indicator if this channel is active
        let isPlaying: Bool = DispatchQueue.main.sync {
            NowPlayingManager.shared.playingItem?.id == channel.id
        }
        if isPlaying {
            item.isPlaying = true
        }

        return item
    }

    // MARK: - Playback

    private func playChannel(_ channel: ChannelDisplayItem) {
        guard !channel.streamURLs.isEmpty else { return }

        // Start playback on main thread (NowPlayingManager is @MainActor)
        DispatchQueue.main.async {
            let headers: [String: String] = {
                if let server = ChannelStore.shared.activeServer {
                    return server.authHeaders
                }
                return ["Accept": "*/*"]
            }()
            NowPlayingManager.shared.startPlaying(channel, headers: headers)
        }

        // Switch to Now Playing template
        let nowPlaying = CPNowPlayingTemplate.shared
        interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
    }
}

// MARK: - UIImage Scaling Helper

private extension UIImage {
    func scaledToFit(_ targetSize: CGSize) -> UIImage {
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height
        let ratio = min(widthRatio, heightRatio)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

#endif

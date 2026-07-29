import SwiftUI

struct PlayingRevealRequest: Equatable {
    let network: Network
    let channelID: Int
    let requiresNetworkSwitch: Bool

    var itemID: String {
        "\(network.rawValue)-\(channelID)"
    }

    static func resolve(
        channelID: Int?,
        playingNetwork: Network?,
        selectedNetwork: Network,
        allNetworksSelected: Bool
    ) -> PlayingRevealRequest? {
        guard let channelID, let playingNetwork else { return nil }
        return PlayingRevealRequest(
            network: playingNetwork,
            channelID: channelID,
            requiresNetworkSwitch: !allNetworksSelected && selectedNetwork != playingNetwork
        )
    }
}

struct StationListView: View {
    @Environment(AppState.self) private var appState
    @State private var allStationsExpanded = Prefs.bool(.allStationsExpanded, default: true)
    @State private var recentExpanded = Prefs.bool(.recentStationsExpanded, default: true)
    @State private var highlightedIndex: Int?
    @State private var pendingPlayingReveal: PlayingRevealRequest?
    @State private var pendingRevealSawLoading = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Network switcher + search
            HStack {
                NetworkPicker()

                Divider()
                    .frame(height: 12)

                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search channels...", text: Bindable(appState).searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) {
                        moveHighlight(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveHighlight(by: -1)
                        return .handled
                    }
                    .onSubmit {
                        let channels = appState.filteredChannels
                        let index = highlightedIndex ?? (appState.searchText.isEmpty ? nil : 0)
                        if let index, channels.indices.contains(index) {
                            appState.playChannel(channels[index])
                        }
                    }
                    .onExitCommand {
                        appState.searchText = ""
                        highlightedIndex = nil
                        searchFocused = false
                    }
                if !appState.searchText.isEmpty {
                    Button(action: { appState.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))

            if appState.isLoading && !appState.hasAnyDisplayedChannels {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading channels...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // pinnedViews makes the section headers sticky: each
                        // pins at the top until the next header pushes it off
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            let searching = !appState.searchText.isEmpty
                            let showFavorites = !searching
                                && (!appState.favoriteChannels.isEmpty || appState.favoritesLoadFailed)
                            let showRecents = !searching && !appState.recentStations.isEmpty
                            let showSections = showFavorites || showRecents

                            // Favorites
                            if showFavorites {
                                Section {
                                    if appState.favoritesLoadFailed && appState.favoriteChannels.isEmpty {
                                        favoritesFailedRow
                                    } else {
                                        ForEach(appState.favoriteChannels) { item in
                                            ChannelRow(item: item, showsNetwork: appState.allNetworksSelected)
                                                .id("fav-\(item.id)")
                                        }
                                    }
                                    Divider()
                                        .padding(.top, 8)
                                } header: {
                                    SectionHeader(
                                        title: favoritesTitle,
                                        showsSyncWarning: !appState.favoritesSyncAvailable
                                    )
                                }
                            }

                            // Recently played (across networks)
                            if showRecents {
                                Section {
                                    if recentExpanded {
                                        ForEach(appState.recentStations) { entry in
                                            RecentRow(entry: entry)
                                        }
                                    }
                                    // So stars on cross-network recents reflect
                                    // server state even before that network loads.
                                    Color.clear.frame(height: 0)
                                        .task { await appState.loadFavoritesForRecents() }
                                    Divider()
                                        .padding(.top, 8)
                                } header: {
                                    SectionHeader(
                                        title: "My Recently Played Channels",
                                        isExpanded: $recentExpanded
                                    )
                                }
                            }

                            if showSections {
                                Section {
                                    if allStationsExpanded {
                                        allChannelRows
                                    }
                                } header: {
                                    SectionHeader(
                                        title: allChannelsTitle,
                                        isExpanded: $allStationsExpanded
                                    )
                                }
                            } else {
                                allChannelRows
                            }
                        }
                    }
                    .frame(height: appState.artworkExpanded ? 180 : 280)
                    .onAppear {
                        searchFocused = true
                        if pendingPlayingReveal != nil {
                            fulfillPendingPlayingReveal(proxy: proxy)
                        } else {
                            scrollToPlayingInCurrentScope(proxy: proxy)
                        }
                    }
                    .background(
                        // Cmd+L jumps to the playing station, as in iTunes
                        Button("") { requestPlayingReveal(proxy: proxy) }
                            .keyboardShortcut("l", modifiers: .command)
                            .opacity(0)
                    )
                    .onChange(of: pendingPlayingRevealIsAvailable) { _, available in
                        if available {
                            fulfillPendingPlayingReveal(proxy: proxy)
                        }
                    }
                    .onChange(of: appState.selectedNetwork) { _, _ in
                        fulfillPendingPlayingReveal(proxy: proxy)
                    }
                    .onChange(of: appState.allNetworksSelected) { _, _ in
                        fulfillPendingPlayingReveal(proxy: proxy)
                    }
                    .onChange(of: highlightedIndex) { _, index in
                        if let index, appState.filteredChannels.indices.contains(index) {
                            proxy.scrollTo("all-\(appState.filteredChannels[index].id)", anchor: .center)
                        }
                    }
                }
            }
        }
        .onChange(of: allStationsExpanded) { _, expanded in
            Prefs.set(expanded, for: .allStationsExpanded)
        }
        .onChange(of: recentExpanded) { _, expanded in
            Prefs.set(expanded, for: .recentStationsExpanded)
        }
        .onChange(of: appState.searchText) { _, _ in
            highlightedIndex = nil
        }
        .onChange(of: searchFocused) { _, focused in
            appState.searchFieldFocused = focused
        }
        .onChange(of: appState.isLoading) { _, loading in
            guard let request = pendingPlayingReveal else { return }
            if loading {
                pendingRevealSawLoading = true
            } else if pendingRevealSawLoading,
                      appState.networkDataCache[request.network]?.isLoaded != true {
                clearPendingPlayingReveal()
            }
        }
    }

    private var favoritesTitle: String {
        appState.allNetworksSelected
            ? "My Favorites"
            : "My \(appState.selectedNetwork.displayName) Favorites"
    }

    private var allChannelsTitle: String {
        let scope = appState.allNetworksSelected ? "" : "\(appState.selectedNetwork.displayName) "
        return "All \(scope)Channels (\(appState.filteredChannels.count))"
    }

    private var pendingPlayingRevealIsAvailable: Bool {
        guard let request = pendingPlayingReveal,
              appState.displayedNetworks.contains(request.network) else { return false }
        return rowTarget(for: request) != nil
    }

    /// Cmd+L is allowed to change scope. Keep that intent pending until a
    /// newly selected site's rows have loaded and rendered.
    private func requestPlayingReveal(proxy: ScrollViewProxy) {
        guard let request = PlayingRevealRequest.resolve(
            channelID: appState.audioPlayer.currentChannel?.id,
            playingNetwork: appState.playingNetwork,
            selectedNetwork: appState.selectedNetwork,
            allNetworksSelected: appState.allNetworksSelected
        ) else {
            clearPendingPlayingReveal()
            return
        }

        pendingPlayingReveal = request
        pendingRevealSawLoading = appState.isLoading

        if request.requiresNetworkSwitch {
            appState.selectNetwork(request.network)
        } else if !appState.searchText.isEmpty,
                  !appState.filteredChannels.contains(where: { $0.id == request.itemID }) {
            // A navigation command should reveal its destination even when
            // the current search happens to filter that station out.
            appState.searchText = ""
        }

        fulfillPendingPlayingReveal(proxy: proxy)
    }

    private func fulfillPendingPlayingReveal(proxy: ScrollViewProxy) {
        guard let request = pendingPlayingReveal else { return }
        if scroll(to: request, proxy: proxy, animated: true) {
            clearPendingPlayingReveal()
        } else if appState.networkDataCache[request.network]?.isLoaded == true {
            // The catalog loaded but no longer contains the playing station.
            clearPendingPlayingReveal()
        }
    }

    /// Opening the panel may center the playing row, but it must never switch
    /// the site the user deliberately chose. Only Cmd+L can do that.
    private func scrollToPlayingInCurrentScope(proxy: ScrollViewProxy) {
        guard let request = PlayingRevealRequest.resolve(
            channelID: appState.audioPlayer.currentChannel?.id,
            playingNetwork: appState.playingNetwork,
            selectedNetwork: appState.selectedNetwork,
            allNetworksSelected: appState.allNetworksSelected
        ), !request.requiresNetworkSwitch else { return }
        _ = scroll(to: request, proxy: proxy, animated: false)
    }

    /// A playing favorite is shown in its Favorites row at the top, not its
    /// duplicate in All Channels. Expanding or replacing list contents needs
    /// one main-loop turn before ScrollViewReader can resolve the row ID.
    @discardableResult
    private func scroll(
        to request: PlayingRevealRequest,
        proxy: ScrollViewProxy,
        animated: Bool
    ) -> Bool {
        guard appState.displayedNetworks.contains(request.network) else { return false }
        guard let target = rowTarget(for: request) else { return false }
        if target.hasPrefix("all-"), !allStationsExpanded {
            allStationsExpanded = true
        }

        let scroll: (String) -> Void = { target in
            if animated {
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            } else {
                proxy.scrollTo(target, anchor: .center)
            }
        }
        DispatchQueue.main.async { scroll(target) }
        return true
    }

    private func rowTarget(for request: PlayingRevealRequest) -> String? {
        let itemId = request.itemID
        if appState.searchText.isEmpty,
           appState.favoriteChannels.contains(where: { $0.id == itemId }) {
            return "fav-\(itemId)"
        }
        if appState.filteredChannels.contains(where: { $0.id == itemId }) {
            return "all-\(itemId)"
        }
        return nil
    }

    private func clearPendingPlayingReveal() {
        pendingPlayingReveal = nil
        pendingRevealSawLoading = false
    }

    private func moveHighlight(by delta: Int) {
        let count = appState.filteredChannels.count
        guard count > 0 else { return }
        // Arrow keys navigate the All Stations list, so make sure it's visible
        if !allStationsExpanded { allStationsExpanded = true }
        let current = highlightedIndex ?? -1
        highlightedIndex = min(max(current + delta, 0), count - 1)
    }

    private var allChannelRows: some View {
        ForEach(Array(appState.filteredChannels.enumerated()), id: \.element.id) { index, item in
            ChannelRow(item: item, isHighlighted: index == highlightedIndex, showsNetwork: appState.allNetworksSelected)
                .id("all-\(item.id)")
        }
    }

    private var favoritesFailedRow: some View {
        HStack(spacing: 6) {
            Text("Couldn't load favorites")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await appState.retryFailedFavorites() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Channel Row

struct ChannelRow: View {
    @Environment(AppState.self) private var appState
    let item: NetworkChannel
    var isHighlighted: Bool = false
    /// All-Sites mode: append the "· Jazz"-style network suffix.
    var showsNetwork: Bool = false
    @State private var isHovered = false

    private var isPlaying: Bool {
        appState.audioPlayer.currentChannel?.id == item.channel.id
            && appState.playingNetwork == item.network
    }

    private var isFavorite: Bool {
        appState.favoriteChannelIds(on: item.network).contains(item.channel.id)
    }

    var body: some View {
        Button(action: { appState.playChannel(item) }) {
            HStack(spacing: 4) {
                Text(item.channel.name)
                    .font(.system(size: 12))
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .playingHighlight(isPlaying)
                if showsNetwork {
                    Text("· \(item.network.shortLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                // Fixed-width slots keep the star column aligned on every row
                SpeakerIndicator(isCurrent: isPlaying, isAudible: appState.audioPlayer.isAudiblyPlaying)

                Group {
                    if isFavorite || isHovered {
                        Button(action: { appState.toggleFavorite(item.channel, on: item.network) }) {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow.opacity(0.65)) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 14)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isPlaying
                ? Color.accentColor.opacity(0.1)
                : (isHighlighted || isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Recent Row

/// Row in the Recently Played section — like ChannelRow but cross-network:
/// shows the network suffix when it isn't the selected one.
struct RecentRow: View {
    @Environment(AppState.self) private var appState
    let entry: RecentStation
    @State private var isHovered = false

    private var isPlaying: Bool {
        appState.audioPlayer.currentChannel?.id == entry.channelId
            && appState.playingNetwork == entry.network
    }

    private var isFavorite: Bool {
        appState.favoriteChannelIds(on: entry.network).contains(entry.channelId)
    }

    var body: some View {
        Button(action: { appState.playRecentStation(entry) }) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 12))
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .playingHighlight(isPlaying)
                if appState.allNetworksSelected || entry.network != appState.selectedNetwork {
                    Text("· \(entry.network.shortLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                SpeakerIndicator(isCurrent: isPlaying, isAudible: appState.audioPlayer.isAudiblyPlaying)

                Group {
                    if isFavorite || isHovered {
                        Button(action: { appState.toggleFavorite(channelId: entry.channelId, name: entry.name, on: entry.network) }) {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow.opacity(0.65)) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 14)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isPlaying
                ? Color.accentColor.opacity(0.1)
                : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var showsSyncWarning: Bool = false
    var isExpanded: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                // Longest titles ("ALL CLASSICAL RADIO CHANNELS (140)") fit,
                // but never let a sticky header wrap to two lines
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if showsSyncWarning {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Favorites saved locally — syncing with the server isn't available")
            }

            if let isExpanded {
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.wrappedValue.toggle()
                    }
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                }
                .buttonStyle(.plain)
                .help(isExpanded.wrappedValue ? "Collapse" : "Expand")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 11)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Behind-window sampling makes this indistinguishable from the panel
        // base at rest, yet it occludes rows sliding under a pinned header —
        // so no pin detection is needed.
        .background(PanelMaterial())
    }
}

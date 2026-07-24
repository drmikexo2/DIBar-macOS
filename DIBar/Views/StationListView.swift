import SwiftUI

struct StationListView: View {
    @Environment(AppState.self) private var appState
    @State private var allStationsExpanded = Prefs.read(key: "all_stations_expanded") != "0"
    @State private var recentExpanded = Prefs.read(key: "recent_stations_expanded") != "0"
    @State private var highlightedIndex: Int?
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

            if appState.isLoading && appState.channels.isEmpty {
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
                                        ForEach(appState.favoriteChannels) { channel in
                                            ChannelRow(channel: channel)
                                                .id("fav-\(channel.id)")
                                        }
                                    }
                                    Divider()
                                        .padding(.top, 8)
                                } header: {
                                    SectionHeader(
                                        title: "Favorite Channels",
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
                                    Divider()
                                        .padding(.top, 8)
                                } header: {
                                    SectionHeader(
                                        title: "Recently Played Channels",
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
                                        title: "All Channels (\(appState.filteredChannels.count))",
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
                        if let playingId = appState.audioPlayer.currentChannel?.id,
                           appState.playingNetwork == appState.selectedNetwork {
                            // A playing favorite is shown in its Favorites row
                            // at the top, not its duplicate down in All Stations
                            if appState.searchText.isEmpty,
                               appState.favoriteChannels.contains(where: { $0.id == playingId }) {
                                proxy.scrollTo("fav-\(playingId)", anchor: .center)
                            } else {
                                proxy.scrollTo("all-\(playingId)", anchor: .center)
                            }
                        }
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
            Prefs.save(key: "all_stations_expanded", value: expanded ? "1" : "0")
        }
        .onChange(of: recentExpanded) { _, expanded in
            Prefs.save(key: "recent_stations_expanded", value: expanded ? "1" : "0")
        }
        .onChange(of: appState.searchText) { _, _ in
            highlightedIndex = nil
        }
        .onChange(of: searchFocused) { _, focused in
            appState.searchFieldFocused = focused
        }
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
        ForEach(Array(appState.filteredChannels.enumerated()), id: \.element.id) { index, channel in
            ChannelRow(channel: channel, isHighlighted: index == highlightedIndex)
                .id("all-\(channel.id)")
        }
    }

    private var favoritesFailedRow: some View {
        HStack(spacing: 6) {
            Text("Couldn't load favorites")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await appState.loadFavorites() }
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
    let channel: Channel
    var isHighlighted: Bool = false
    @State private var isHovered = false

    private var isPlaying: Bool {
        appState.audioPlayer.currentChannel?.id == channel.id
            && appState.playingNetwork == appState.selectedNetwork
    }

    private var isFavorite: Bool {
        appState.favoriteChannelIds.contains(channel.id)
    }

    var body: some View {
        Button(action: { appState.playChannel(channel) }) {
            HStack(spacing: 4) {
                Text(channel.name)
                    .font(.system(size: 12))
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                Spacer()

                // Fixed-width slots keep the star column aligned on every row
                Group {
                    if isPlaying && appState.audioPlayer.isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    } else if isPlaying {
                        Image(systemName: "speaker.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 14)

                Group {
                    if isFavorite || isHovered {
                        Button(action: { appState.toggleFavorite(channel) }) {
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
/// shows the network suffix when it isn't the selected one, no star slot.
struct RecentRow: View {
    @Environment(AppState.self) private var appState
    let entry: RecentStation
    @State private var isHovered = false

    private var isPlaying: Bool {
        appState.audioPlayer.currentChannel?.id == entry.channelId
            && appState.playingNetwork == entry.network
    }

    var body: some View {
        Button(action: { appState.playRecentStation(entry) }) {
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(.system(size: 12))
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                if entry.network != appState.selectedNetwork {
                    Text("· \(entry.network.shortLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                Group {
                    if isPlaying && appState.audioPlayer.isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    } else if isPlaying {
                        Image(systemName: "speaker.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
        // Full width regardless of chevron presence, with an opaque-ish
        // backing so rows don't bleed through while pinned
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

import SwiftUI

struct StationListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search stations...", text: Bindable(appState).searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !appState.searchText.isEmpty {
                    Button(action: { appState.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))

            if appState.isLoading && appState.channels.isEmpty {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading stations...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Favorites
                            if appState.searchText.isEmpty && !appState.favoriteChannels.isEmpty {
                                SectionHeader(title: "Favorites")
                                ForEach(appState.favoriteChannels) { channel in
                                    ChannelRow(channel: channel)
                                        .id("fav-\(channel.id)")
                                }

                                Divider()
                                    .padding(.top, 8)

                                SectionHeader(title: "All Stations")
                            }

                            ForEach(appState.filteredChannels) { channel in
                                ChannelRow(channel: channel)
                                    .id("all-\(channel.id)")
                            }
                        }
                    }
                    .frame(height: 280)
                    .onAppear {
                        if let playingId = appState.audioPlayer.currentChannel?.id,
                           appState.playingNetwork == appState.selectedNetwork {
                            proxy.scrollTo("all-\(playingId)", anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Channel Row

struct ChannelRow: View {
    @Environment(AppState.self) private var appState
    let channel: Channel
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
            HStack(spacing: 6) {
                Text(channel.name)
                    .font(.system(size: 12))
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow.opacity(0.65))
                }
                if isPlaying && appState.audioPlayer.isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                } else if isPlaying {
                    Image(systemName: "speaker.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
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

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

import SwiftUI
import os

private let log = Logger(subsystem: "com.dibar", category: "PlayerControls")

struct PlayerControlsView: View {
    @Environment(AppState.self) private var appState

    private var player: AudioPlayer { appState.audioPlayer }
    private let expandedArtSize: CGFloat = 220

    var body: some View {
        VStack(spacing: 8) {
            if let track = player.currentTrack {
                if appState.artworkExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        expandedArtwork
                        trackInfoView(track: track, lineLimit: 2)
                    }
                } else {
                    HStack(spacing: 10) {
                        collapsedArtwork
                        trackInfoView(track: track, lineLimit: 1)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("Not Playing")
                    .font(.headline)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                Group {
                    // Space toggles playback unless the user is typing in search
                    if appState.searchFieldFocused {
                        playPauseButton
                    } else {
                        playPauseButton
                            .keyboardShortcut(.space, modifiers: [])
                    }
                }

                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(player.volume) },
                        set: { player.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: player.currentTrackIdentityToken) { _, _ in
            appState.artworkExpanded = false
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("debugToggleArt"))) { _ in
            let hasArt = player.currentArtImage != nil
            log.error("DEBUG toggleArt: appState.artworkExpanded=\(appState.artworkExpanded, privacy: .public) hasArt=\(hasArt, privacy: .public)")
            if hasArt {
                withAnimation(.easeInOut(duration: 0.2)) { appState.artworkExpanded.toggle() }
                log.error("DEBUG toggleArt: appState.artworkExpanded now=\(appState.artworkExpanded, privacy: .public)")
            }
        }
        #endif
    }

    private var playPauseButton: some View {
        Button(action: { appState.togglePlayPause() }) {
            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 28))
        }
        .buttonStyle(.plain)
        .disabled(player.currentChannel == nil)
    }

    private var collapsedArtwork: some View {
        Group {
            if let nsImage = player.currentArtImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { toggleArtworkExpansion() }
        .cursor(.pointingHand)
    }

    private var expandedArtwork: some View {
        Group {
            if let nsImage = player.currentArtImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: expandedArtSize, height: expandedArtSize)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity)
        .onTapGesture { toggleArtworkExpansion() }
        .cursor(.pointingHand)
    }

    private func trackInfoView(track: NowPlaying, lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            channelLine(track: track)

            Text(track.displayText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)

            TrackMetaRow(track: track)
        }
    }

    /// "Network · Channel"; when browsing a different network than the one
    /// playing, tapping it jumps back to the playing network's station list.
    @ViewBuilder
    private func channelLine(track: NowPlaying) -> some View {
        let network = player.currentNetwork
        let label = network.map { "\($0.displayName) · \(track.channelName)" } ?? track.channelName
        if let network, network != appState.selectedNetwork {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .onTapGesture { appState.selectNetwork(network) }
                .cursor(.pointingHand)
                .help("Show \(network.displayName) stations")
        } else {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
    }

    private func toggleArtworkExpansion() {
        withAnimation(.easeInOut(duration: 0.2)) {
            appState.artworkExpanded.toggle()
        }
    }
}

// MARK: - Cursor helper

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Track Meta Row

struct TrackMetaRow: View {
    @Environment(AppState.self) private var appState
    let track: NowPlaying
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            // Votes — interactive when the track is identified
            if track.trackId != nil {
                let myVote = appState.currentTrackVote

                Button(action: { appState.voteCurrentTrack(up: true) }) {
                    HStack(spacing: 2) {
                        Image(systemName: myVote == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                        Text("\(track.upVotes)")
                    }
                    .foregroundStyle(.green.opacity(myVote == 1 ? 1.0 : 0.7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .help(myVote == 1 ? "Remove your like" : "Like this song")

                Button(action: { appState.voteCurrentTrack(up: false) }) {
                    HStack(spacing: 2) {
                        Image(systemName: myVote == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        Text("\(track.downVotes)")
                    }
                    .foregroundStyle(.red.opacity(myVote == -1 ? 0.9 : 0.55))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .help(myVote == -1 ? "Remove your dislike" : "Dislike this song")
            } else if track.upVotes > 0 || track.downVotes > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "hand.thumbsup.fill")
                    Text("\(track.upVotes)")
                }
                .foregroundStyle(.green.opacity(0.8))

                HStack(spacing: 2) {
                    Image(systemName: "hand.thumbsdown.fill")
                    Text("\(track.downVotes)")
                }
                .foregroundStyle(.red.opacity(0.6))
            }

            // Elapsed / Duration
            if let elapsed = elapsedSeconds {
                Spacer(minLength: 0)
                if track.duration > 0 {
                    let clamped = min(max(elapsed, 0), track.duration)
                    Text("\(NowPlaying.formatTime(clamped)) / \(NowPlaying.formatTime(track.duration))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("\(NowPlaying.formatTime(max(elapsed, 0)))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 10))
        .onReceive(timer) { now = $0 }
        .onAppear { appState.refreshCurrentTrackVote() }
        .onChange(of: track.trackId) { _, _ in
            appState.refreshCurrentTrackVote()
        }
    }

    private var elapsedSeconds: Int? {
        if let override = track.elapsedOverride {
            return max(override, 0)
        }
        guard let startedAt = track.startedAt else { return nil }
        return max(Int(now.timeIntervalSince(startedAt)), 0)
    }
}

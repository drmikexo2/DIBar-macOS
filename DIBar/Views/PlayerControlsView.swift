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

                Button(action: { player.toggleMute() }) {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.caption2)
                        .foregroundStyle(player.isMuted ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .help(player.isMuted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(
                        get: { Double(player.volume) },
                        set: { player.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                // Dimmed while muted, but still live — dragging unmutes
                .opacity(player.isMuted ? 0.4 : 1)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                OutputDevicePicker()

                SleepTimerView()
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
                appState.artworkExpanded.toggle()
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

    @ViewBuilder
    private func trackInfoView(track: NowPlaying, lineLimit: Int) -> some View {
        let hasSongMetadata = !(track.artist.isEmpty && track.title.isEmpty)
        let info = VStack(alignment: .leading, spacing: 2) {
            channelLine(track: track)

            Text(track.displayText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .help(hasSongMetadata ? track.displayText : "")

            TrackMetaRow(track: track)
        }
        if hasSongMetadata {
            info.songActionsMenu(artist: track.artist, title: track.title)
        } else {
            info
        }
    }

    /// "Network · Channel"; when browsing a different network than the one
    /// playing, tapping it jumps back to the playing network's station list.
    @ViewBuilder
    private func channelLine(track: NowPlaying) -> some View {
        let network = player.currentNetwork
        let label = network.map { "\($0.displayName) · \(track.channelName)" } ?? track.channelName
        // In All-Sites mode the playing channel is already on screen, and the
        // jump would drop the user out of All mode — plain text instead.
        if let network, !appState.allNetworksSelected, network != appState.selectedNetwork {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .onTapGesture { appState.selectNetwork(network) }
                .cursor(.pointingHand)
                .help("Show \(network.displayName) channels")
        } else {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
    }

    private func toggleArtworkExpansion() {
        // Never animate this: it changes the panel's preferred size, and
        // SwiftUI animating the NSPanel frame re-lays-out the whole AppKit
        // hierarchy per frame — enough constraint churn to overflow the main
        // thread's stack in the layout engine (crash 2026-07-24).
        appState.artworkExpanded.toggle()
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

    var body: some View {
        HStack(spacing: 6) {
            // Votes — interactive when the track is identified
            if track.trackId != nil {
                let myVote = appState.currentTrackVote

                Button(action: { appState.voteCurrentTrack(up: true) }) {
                    HStack(spacing: 2) {
                        Image(systemName: myVote == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                        // Count includes the user's own vote for instant feedback
                        Text("\(track.upVotes + (myVote == 1 ? 1 : 0))")
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
                        Text("\(track.downVotes + (myVote == -1 ? 1 : 0))")
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

            if hasSongMetadata {
                SongActionsButton(artist: track.artist, title: track.title)
            }

            // Transport state while the stream recovers, else elapsed/duration
            if isBufferingOrReconnecting {
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.mini)
                Text(appState.audioPlayer.isRecovering ? "Reconnecting…" : "Buffering…")
                    .foregroundStyle(.secondary)
            } else if track.elapsedOverride != nil || track.startedAt != nil {
                Spacer(minLength: 0)
                // TimelineView ticks only while this row is on screen, unlike
                // a connected Timer publisher.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let elapsed = elapsedSeconds(at: context.date) {
                        if track.duration > 0 {
                            let clamped = min(max(elapsed, 0), track.duration)
                            Text("\(NowPlaying.formatTime(clamped)) / \(NowPlaying.formatTime(track.duration))")
                        } else {
                            Text("\(NowPlaying.formatTime(max(elapsed, 0)))")
                        }
                    }
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .font(.system(size: 10))
        .onAppear { appState.refreshCurrentTrackVote() }
        .onChange(of: track.trackId) { _, _ in
            appState.refreshCurrentTrackVote()
        }
    }

    private var hasSongMetadata: Bool {
        !(track.artist.isEmpty && track.title.isEmpty) && track.title != "Loading..."
    }

    private var isBufferingOrReconnecting: Bool {
        switch appState.audioPlayer.phase {
        case .buffering, .reconnecting: return true
        default: return false
        }
    }

    private func elapsedSeconds(at now: Date) -> Int? {
        track.elapsedSeconds(at: now)
    }
}

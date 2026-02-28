import SwiftUI
import os

private let log = Logger(subsystem: "com.dibar", category: "PlayerControls")

struct PlayerControlsView: View {
    @Environment(AppState.self) private var appState
    @State private var artExpanded = false

    private var player: AudioPlayer { appState.audioPlayer }

    var body: some View {
        VStack(spacing: 8) {
            if let track = player.currentTrack {
                HStack(spacing: 10) {
                    // Album art — single view, changes size on tap
                    if let nsImage = player.currentArtImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: artExpanded ? .fit : .fill)
                            .frame(width: artExpanded ? nil : 48, height: artExpanded ? nil : 48)
                            .frame(maxWidth: artExpanded ? .infinity : nil)
                            .clipShape(RoundedRectangle(cornerRadius: artExpanded ? 8 : 6))
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) { artExpanded.toggle() }
                            }
                            .cursor(.pointingHand)
                    } else if !artExpanded {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if !artExpanded {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.channelName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)

                            Text(track.displayText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            TrackMetaRow(track: track)
                        }

                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("Not Playing")
                    .font(.headline)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                Button(action: { appState.togglePlayPause() }) {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(player.currentChannel == nil)

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
        .onChange(of: player.currentTrack) { _, _ in
            artExpanded = false
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("debugToggleArt"))) { _ in
            let hasArt = player.currentArtImage != nil
            log.error("DEBUG toggleArt: artExpanded=\(artExpanded, privacy: .public) hasArt=\(hasArt, privacy: .public)")
            if hasArt {
                withAnimation(.easeInOut(duration: 0.2)) { artExpanded.toggle() }
                log.error("DEBUG toggleArt: artExpanded now=\(artExpanded, privacy: .public)")
            }
        }
        #endif
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
    let track: NowPlaying
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            // Votes
            if track.upVotes > 0 || track.downVotes > 0 {
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
            if track.duration > 0, let startedAt = track.startedAt {
                let elapsed = min(Int(now.timeIntervalSince(startedAt)), track.duration)
                Spacer(minLength: 0)
                Text("\(NowPlaying.formatTime(max(elapsed, 0))) / \(NowPlaying.formatTime(track.duration))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10))
        .onReceive(timer) { now = $0 }
    }
}

import AppKit
import AVFoundation
import MediaPlayer
import Combine
import os

private let log = Logger(subsystem: "com.dibar", category: "AudioPlayer")

@Observable
@MainActor
final class AudioPlayer {
    var isPlaying: Bool = false
    var volume: Float = 0.75
    var currentChannel: Channel?
    var currentTrack: NowPlaying?
    var currentArtImage: NSImage?

    private var player: AVPlayer?
    private var trackPollTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?

    init() {
        setupRemoteCommands()
    }

    // MARK: - Playback

    func play(channel: Channel, streamURL: URL) {
        // Stop existing polling and observation
        trackPollTask?.cancel()
        statusObservation?.invalidate()
        statusObservation = nil

        // Release old player item before loading new one
        player?.replaceCurrentItem(with: nil)

        if player == nil {
            player = AVPlayer()
            player?.volume = volume
        }

        let item = AVPlayerItem(url: streamURL)

        // Observe item status for errors — avoid capturing playerItem
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            let error = observed.error?.localizedDescription
            Task { @MainActor [weak self] in
                switch status {
                case .failed:
                    self?.isPlaying = false
                    _ = error // silence unused warning
                default:
                    break
                }
            }
        }

        player?.replaceCurrentItem(with: item)
        player?.play()

        currentChannel = channel
        isPlaying = true
        currentArtImage = nil

        currentTrack = NowPlaying(channelName: channel.name, artist: "", title: "Loading...", artURL: nil, duration: 0, startedAt: nil, upVotes: 0, downVotes: 0)
        updateNowPlaying()
        startTrackPolling(channelId: channel.id, channelName: channel.name)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
        trackPollTask?.cancel()
        trackPollTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        isPlaying = false
        currentChannel = nil
        currentTrack = nil
        currentArtImage = nil
        clearNowPlaying()
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        player?.volume = newVolume
    }

    // MARK: - Now Playing Info Center

    private func updateNowPlaying() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTrack?.title ?? currentChannel?.name ?? "DIBar"
        info[MPMediaItemPropertyArtist] = currentTrack?.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentChannel?.name ?? "DI.FM"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Remote Commands (Media Keys)

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        // Disable skip commands (not applicable for radio)
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    // MARK: - Track Polling

    private func startTrackPolling(channelId: Int, channelName: String) {
        trackPollTask = Task { [weak self] in
            await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName)

            while !Task.isCancelled {
                if let remaining = self?.currentTrack?.timeRemaining, remaining > 0, remaining < 30 {
                    // Near track end — sleep until track_end + 1s
                    log.error("POLL: sleeping \(remaining + 1, privacy: .public)s (track_end+1, remaining=\(remaining, privacy: .public))")
                    try? await Task.sleep(for: .seconds(remaining + 1))
                    guard !Task.isCancelled, self != nil else { break }

                    let oldTrack = self?.currentTrack
                    await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName)

                    // Retry at +3s, +5s, +7s, +9s if API hasn't updated
                    if self?.currentTrack == oldTrack {
                        for attempt in 1...4 {
                            let offset = 1 + attempt * 2 // +3, +5, +7, +9
                            log.error("POLL: retry \(attempt, privacy: .public)/4 (track_end+\(offset, privacy: .public)s)")
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled, self != nil else { break }
                            await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName)
                            if self?.currentTrack != oldTrack { break }
                        }
                    }
                } else {
                    // Normal 30s poll
                    log.error("POLL: sleeping 30s (timeRemaining=\(self?.currentTrack?.timeRemaining?.description ?? "nil", privacy: .public))")
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, self != nil else { break }
                    await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName)
                }
            }
        }
    }

    private func fetchAndUpdateTrack(channelId: Int, channelName: String) async {
        guard let item = try? await DIClient.fetchCurrentTrack(channelId: channelId) else { return }

        let artist = item.artist ?? ""
        let title = item.title ?? item.track ?? ""

        var artURL: URL?
        if let art = item.artUrl, !art.isEmpty {
            let urlStr = art.hasPrefix("//") ? "https:\(art)" : art
            artURL = URL(string: urlStr)
        }

        let startedAt: Date? = item.started.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        let newTrack = NowPlaying(
            channelName: channelName,
            artist: artist,
            title: title,
            artURL: artURL,
            duration: item.duration ?? 0,
            startedAt: startedAt,
            upVotes: item.votes?.up ?? 0,
            downVotes: item.votes?.down ?? 0
        )

        let trackChanged = currentTrack != newTrack
        log.error("POLL: '\(artist, privacy: .public) — \(title, privacy: .public)' changed=\(trackChanged, privacy: .public)")
        if trackChanged {
            currentTrack = newTrack
            updateNowPlaying()
            let loadedImage = await loadArtImage(url: artURL)
            currentArtImage = loadedImage
            await updateNowPlayingArtwork(image: loadedImage)
        }
    }

    private func loadArtImage(url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let sized = URL(string: url.absoluteString + "?size=300x300") ?? url
        guard let (data, _) = try? await URLSession.shared.data(from: sized) else { return nil }
        return NSImage(data: data)
    }

    private func updateNowPlayingArtwork(image: NSImage?) async {
        guard let image else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

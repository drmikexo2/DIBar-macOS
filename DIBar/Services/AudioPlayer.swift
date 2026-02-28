import AppKit
import AVFoundation
import MediaPlayer
import Combine
import os

private let log = Logger(subsystem: "com.dibar", category: "AudioPlayer")

@Observable
@MainActor
final class AudioPlayer {
    private enum TimingMode {
        case startupFrozen
        case icyAnchored
        case frozenNoIcy
    }

    var isPlaying: Bool = false
    var volume: Float = 0.75
    var currentChannel: Channel?
    var currentTrack: NowPlaying?
    var currentArtImage: NSImage?
    var currentTrackIdentityToken: String?

    private var player: AVPlayer?
    private var trackPollTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var metadataDelegate: StreamMetadataDelegate?
    private let normalPollIntervalSeconds = 10
    private var apiTrackIdentity: String?
    private var apiTrackStartedAt: Date?
    private var apiTrackDuration: Int = 0
    private var playbackSessionID = UUID()
    private var lastIcyStreamTitle: String?
    private var lastIcyLogicalKey: String?
    private var timingMode: TimingMode = .startupFrozen
    private var audibleStartedAt: Date?
    private var frozenElapsedSeconds: Int = 0

    init() {
        setupRemoteCommands()
    }

    // MARK: - Playback

    func play(channel: Channel, streamURL: URL) {
        // Stop existing polling and observation
        trackPollTask?.cancel()
        statusObservation?.invalidate()
        statusObservation = nil
        metadataOutput = nil
        metadataDelegate = nil

        // Release old player item before loading new one
        player?.replaceCurrentItem(with: nil)

        if player == nil {
            player = AVPlayer()
            player?.volume = volume
        }

        let sessionID = UUID()
        playbackSessionID = sessionID
        lastIcyStreamTitle = nil
        lastIcyLogicalKey = nil
        timingMode = .startupFrozen
        audibleStartedAt = nil
        frozenElapsedSeconds = 0

        let asset = AVURLAsset(
            url: streamURL,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Icy-MetaData": "1"]]
        )
        let item = AVPlayerItem(asset: asset)

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
        installMetadataOutput(on: item, channelId: channel.id, channelName: channel.name, sessionID: sessionID)

        player?.replaceCurrentItem(with: item)
        player?.play()

        currentChannel = channel
        isPlaying = true
        currentArtImage = nil
        currentTrackIdentityToken = nil
        apiTrackIdentity = nil
        apiTrackStartedAt = nil
        apiTrackDuration = 0

        currentTrack = NowPlaying(
            channelName: channel.name,
            artist: "",
            title: "Loading...",
            trackId: nil,
            artURL: nil,
            duration: 0,
            startedAt: nil,
            elapsedOverride: 0,
            upVotes: 0,
            downVotes: 0
        )
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
        metadataOutput = nil
        metadataDelegate = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        isPlaying = false
        currentChannel = nil
        currentTrack = nil
        currentArtImage = nil
        currentTrackIdentityToken = nil
        apiTrackIdentity = nil
        apiTrackStartedAt = nil
        apiTrackDuration = 0
        playbackSessionID = UUID()
        lastIcyStreamTitle = nil
        lastIcyLogicalKey = nil
        timingMode = .startupFrozen
        audibleStartedAt = nil
        frozenElapsedSeconds = 0
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
                if let remaining = self?.apiTimeRemaining, remaining > 0, remaining < 30 {
                    // Near track end — sleep until track_end + 1s
                    log.error("POLL: sleeping \(remaining + 1, privacy: .public)s (track_end+1, remaining=\(remaining, privacy: .public))")
                    try? await Task.sleep(for: .seconds(remaining + 1))
                    guard !Task.isCancelled, self != nil else { break }

                    let oldIdentity = self?.apiTrackIdentity
                    await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName)

                    // Retry at +3s, +5s, +7s, +9s if API hasn't updated
                    if self?.apiTrackIdentity == oldIdentity {
                        for attempt in 1...4 {
                            let offset = 1 + attempt * 2 // +3, +5, +7, +9
                            log.error("POLL: retry \(attempt, privacy: .public)/4 (track_end+\(offset, privacy: .public)s)")
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled, self != nil else { break }
                            await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName)
                            if self?.apiTrackIdentity != oldIdentity { break }
                        }
                    }
                } else {
                    // Normal poll
                    log.error("POLL: sleeping \(self?.normalPollIntervalSeconds ?? 10, privacy: .public)s (apiTimeRemaining=\(self?.apiTimeRemaining?.description ?? "nil", privacy: .public))")
                    try? await Task.sleep(for: .seconds(self?.normalPollIntervalSeconds ?? 10))
                    guard !Task.isCancelled, self != nil else { break }
                    await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName)
                }
            }
        }
    }

    private func fetchAndUpdateTrack(channelId: Int, channelName: String) async {
        guard let item = try? await DIClient.fetchCurrentTrack(channelId: channelId) else { return }

        let apiArtist = item.artist ?? ""
        let apiTitle = item.title ?? item.track ?? ""
        let apiLogicalKey = logicalTrackKey(artist: apiArtist, title: apiTitle)
        let upVotes = item.votes?.up ?? 0
        let downVotes = item.votes?.down ?? 0

        var artURL: URL?
        if let art = item.artUrl, !art.isEmpty {
            let urlStr = art.hasPrefix("//") ? "https:\(art)" : art
            artURL = URL(string: urlStr)
        }

        let apiStartedAt: Date? = item.started.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let identity = resolveTrackIdentity(item: item, artist: apiArtist, title: apiTitle)
        let apiDuration = item.duration ?? 0

        apiTrackIdentity = identity
        apiTrackStartedAt = apiStartedAt
        apiTrackDuration = apiDuration

        let previousTrack = currentTrack
        let previousArtURL = previousTrack?.artURL
        var nextTrack = previousTrack ?? NowPlaying(
            channelName: channelName,
            artist: "",
            title: "Loading...",
            trackId: nil,
            artURL: nil,
            duration: 0,
            startedAt: nil,
            elapsedOverride: 0,
            upVotes: 0,
            downVotes: 0
        )
        var shouldUpdateTrack = false

        switch timingMode {
        case .startupFrozen:
            let displayArtist = apiArtist.isEmpty ? nextTrack.artist : apiArtist
            let displayTitle = apiTitle.isEmpty ? nextTrack.title : apiTitle

            nextTrack = NowPlaying(
                channelName: channelName,
                artist: displayArtist,
                title: displayTitle,
                trackId: item.trackId ?? nextTrack.trackId,
                artURL: artURL ?? nextTrack.artURL,
                duration: apiDuration,
                startedAt: apiStartedAt ?? nextTrack.startedAt,
                elapsedOverride: nil,
                upVotes: upVotes,
                downVotes: downVotes
            )
            shouldUpdateTrack = true

        case .icyAnchored:
            let currentLogicalKey = currentLogicalTrackKey
            if let apiLogicalKey, let currentLogicalKey, apiLogicalKey == currentLogicalKey {
                nextTrack = NowPlaying(
                    channelName: channelName,
                    artist: nextTrack.artist,
                    title: nextTrack.title,
                    trackId: item.trackId ?? nextTrack.trackId,
                    artURL: artURL ?? nextTrack.artURL,
                    duration: apiDuration,
                    startedAt: audibleStartedAt ?? nextTrack.startedAt,
                    elapsedOverride: nil,
                    upVotes: upVotes,
                    downVotes: downVotes
                )
                shouldUpdateTrack = true
            } else if let apiLogicalKey, let currentLogicalKey, apiLogicalKey != currentLogicalKey {
                // API moved to another track before ICY reported it. Freeze until ICY catches up.
                frozenElapsedSeconds = currentElapsedSeconds()
                timingMode = .frozenNoIcy
                nextTrack = NowPlaying(
                    channelName: nextTrack.channelName,
                    artist: nextTrack.artist,
                    title: nextTrack.title,
                    trackId: nextTrack.trackId,
                    artURL: nextTrack.artURL,
                    duration: nextTrack.duration,
                    startedAt: nextTrack.startedAt,
                    elapsedOverride: frozenElapsedSeconds,
                    upVotes: nextTrack.upVotes,
                    downVotes: nextTrack.downVotes
                )
                shouldUpdateTrack = true
                log.error("POLL: API/ICY mismatch — freezing elapsed at \(self.frozenElapsedSeconds, privacy: .public)s")
            } else {
                // No stable API title to merge; keep current audible state.
                shouldUpdateTrack = false
            }

        case .frozenNoIcy:
            let currentLogicalKey = currentLogicalTrackKey
            if let apiLogicalKey, let currentLogicalKey, apiLogicalKey == currentLogicalKey {
                nextTrack = NowPlaying(
                    channelName: channelName,
                    artist: nextTrack.artist,
                    title: nextTrack.title,
                    trackId: item.trackId ?? nextTrack.trackId,
                    artURL: artURL ?? nextTrack.artURL,
                    duration: apiDuration,
                    startedAt: nextTrack.startedAt,
                    elapsedOverride: frozenElapsedSeconds,
                    upVotes: upVotes,
                    downVotes: downVotes
                )
                shouldUpdateTrack = true
            }
        }

        if shouldUpdateTrack {
            currentTrack = nextTrack
            if timingMode == .startupFrozen {
                currentTrackIdentityToken = identity
            }
            updateNowPlaying()
        }

        let shouldReloadArt = shouldUpdateTrack && (previousArtURL != nextTrack.artURL)
        if shouldReloadArt {
            let loadedImage = await loadArtImage(url: nextTrack.artURL)
            if let loadedImage {
                currentArtImage = loadedImage
                await updateNowPlayingArtwork(image: loadedImage)
            } else if previousArtURL != nil {
                currentArtImage = nil
            }
        }
    }

    private func installMetadataOutput(on item: AVPlayerItem, channelId: Int, channelName: String, sessionID: UUID) {
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        let delegate = StreamMetadataDelegate(
            owner: self,
            channelId: channelId,
            channelName: channelName,
            sessionID: sessionID
        )

        output.setDelegate(delegate, queue: DispatchQueue(label: "com.dibar.metadata"))
        output.advanceIntervalForDelegateInvocation = 0.15
        item.add(output)

        metadataOutput = output
        metadataDelegate = delegate
    }

    fileprivate func handleTimedMetadata(
        _ groups: [AVTimedMetadataGroup],
        channelId: Int,
        channelName: String,
        sessionID: UUID
    ) async {
        guard sessionID == playbackSessionID else { return }

        for group in groups {
            for item in group.items {
                guard let streamTitle = await extractIcyStreamTitle(from: item) else { continue }
                await handleIcyStreamTitle(streamTitle, channelId: channelId, channelName: channelName, sessionID: sessionID)
                return
            }
        }
    }

    private func handleIcyStreamTitle(_ streamTitle: String, channelId: Int, channelName: String, sessionID: UUID) async {
        guard sessionID == playbackSessionID else { return }

        let normalizedTitle = streamTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return }

        let (artist, title) = splitArtistAndTitle(from: normalizedTitle)
        let logicalKey = logicalTrackKey(artist: artist, title: title) ?? normalizedTitle.lowercased()

        // Hybrid timing: keep API-based elapsed at startup. The first ICY title packet is
        // only used to seed ICY state, not to reset elapsed to zero.
        if lastIcyStreamTitle == nil {
            lastIcyStreamTitle = normalizedTitle
            lastIcyLogicalKey = logicalKey

            if let existing = currentTrack,
               existing.title == "Loading..." || existing.title.isEmpty {
                currentTrack = NowPlaying(
                    channelName: channelName,
                    artist: artist,
                    title: title,
                    trackId: existing.trackId,
                    artURL: existing.artURL,
                    duration: existing.duration,
                    startedAt: existing.startedAt,
                    elapsedOverride: existing.elapsedOverride,
                    upVotes: existing.upVotes,
                    downVotes: existing.downVotes
                )
                updateNowPlaying()
            }

            log.error("ICY: initial stream title seed '\(normalizedTitle, privacy: .public)'")
            await fetchAndUpdateTrack(channelId: channelId, channelName: channelName)
            return
        }

        guard normalizedTitle != lastIcyStreamTitle else { return }
        lastIcyStreamTitle = normalizedTitle

        lastIcyLogicalKey = logicalKey
        timingMode = .icyAnchored
        audibleStartedAt = Date()
        frozenElapsedSeconds = 0
        currentArtImage = nil

        currentTrack = NowPlaying(
            channelName: channelName,
            artist: artist,
            title: title,
            trackId: nil,
            artURL: nil,
            duration: 0,
            startedAt: audibleStartedAt,
            elapsedOverride: nil,
            upVotes: 0,
            downVotes: 0
        )
        currentTrackIdentityToken = "icy:\(logicalKey)"
        updateNowPlaying()

        log.error("ICY: stream title update '\(normalizedTitle, privacy: .public)'")

        // Pull full metadata (duration/votes/art/started) as soon as stream title changes.
        await fetchAndUpdateTrack(channelId: channelId, channelName: channelName)
    }

    private func extractIcyStreamTitle(from item: AVMetadataItem) async -> String? {
        let identifierRaw = item.identifier?.rawValue.lowercased() ?? ""
        let keySpaceRaw = item.keySpace?.rawValue.lowercased() ?? ""
        let keyRaw = String(describing: item.key).lowercased()
        let looksLikeStreamTitle =
            identifierRaw.contains("streamtitle")
            || (keySpaceRaw == "icy" && keyRaw.contains("streamtitle"))
            || keyRaw == "optional(streamtitle)"

        guard looksLikeStreamTitle else { return nil }

        if let text = try? await item.load(.stringValue),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let value = try? await item.load(.value) {
            if let text = value as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let text = value as? NSString,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text as String
            }
        }

        return nil
    }

    private func splitArtistAndTitle(from streamTitle: String) -> (String, String) {
        let separators = [" - ", " — ", " – "]

        for separator in separators {
            if let range = streamTitle.range(of: separator) {
                let artist = String(streamTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = String(streamTitle[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !artist.isEmpty && !title.isEmpty {
                    return (artist, title)
                }
            }
        }

        return ("", streamTitle)
    }

    private func logicalTrackKey(artist: String, title: String) -> String? {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedArtist.isEmpty && normalizedTitle.isEmpty { return nil }
        return "\(normalizedArtist)|\(normalizedTitle)"
    }

    private var currentLogicalTrackKey: String? {
        guard let track = currentTrack else { return nil }
        return logicalTrackKey(artist: track.artist, title: track.title)
    }

    private func currentElapsedSeconds(now: Date = Date()) -> Int {
        guard let track = currentTrack else { return 0 }
        if let override = track.elapsedOverride {
            return max(override, 0)
        }
        guard let startedAt = track.startedAt else { return 0 }
        return max(Int(now.timeIntervalSince(startedAt)), 0)
    }

    private var apiTimeRemaining: Int? {
        guard let apiTrackStartedAt, apiTrackDuration > 0 else { return nil }
        let elapsed = Int(Date().timeIntervalSince(apiTrackStartedAt))
        let remaining = apiTrackDuration - elapsed
        return remaining > 0 ? remaining : nil
    }

    private func resolveTrackIdentity(item: TrackHistoryItem, artist: String, title: String) -> String {
        if let trackId = item.trackId {
            return "id:\(trackId)"
        }

        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let started = item.started {
            return "meta:\(normalizedArtist)|\(normalizedTitle)|\(started)"
        }

        return "meta:\(normalizedArtist)|\(normalizedTitle)"
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

private final class StreamMetadataDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    weak var owner: AudioPlayer?
    let channelId: Int
    let channelName: String
    let sessionID: UUID

    init(owner: AudioPlayer, channelId: Int, channelName: String, sessionID: UUID) {
        self.owner = owner
        self.channelId = channelId
        self.channelName = channelName
        self.sessionID = sessionID
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        Task { [weak owner] in
            await owner?.handleTimedMetadata(groups, channelId: channelId, channelName: channelName, sessionID: sessionID)
        }
    }
}

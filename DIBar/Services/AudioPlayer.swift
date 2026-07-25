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

    /// What the transport is actually doing. `isPlaying` stays "the user wants
    /// playback" so state diffing in HistoryRecorder keeps working unchanged.
    enum PlaybackPhase: Equatable {
        case idle
        case buffering
        case playing
        case paused
        case reconnecting(attempt: Int)
        case failed
    }

    var isPlaying: Bool = false
    var volume: Float = 0.75
    /// Session-only, like volume: never persisted. `volume` keeps the user's
    /// level while muted (the implicit stash); only the AVPlayer is zeroed.
    var isMuted: Bool = false

    // ◀◀/▶▶ media-key actions, set by AppState (favorite-channel cycling)
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    var playbackError: String?
    var currentChannel: Channel?
    var currentNetwork: Network?
    var currentTrack: NowPlaying?
    var currentArtImage: NSImage?
    var currentTrackIdentityToken: String?
    var phase: PlaybackPhase = .idle

    var isRecovering: Bool {
        if case .reconnecting = phase { return true }
        return false
    }

    private var player: AVPlayer?
    private var trackPollTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
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

    // Reconnect state
    private var lastPlayArgs: (channel: Channel, url: URL, network: Network)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var hasPlayedThisSession = false
    private var isReconnectRestart = false
    private var autoResumeOnNetworkReturn = false
    private var lastItemError: String?
    private var pausedAt: Date?
    private var itemNotificationTokens: [NSObjectProtocol] = []
    private var recovery: PlaybackRecovery?
    private static let reconnectBackoff: [Double] = [1, 2, 4, 8, 15, 30, 30, 30]

    init() {
        setupRemoteCommands()
        recovery = PlaybackRecovery(player: self)
    }

    // MARK: - Playback

    func play(channel: Channel, streamURL: URL, network: Network) {
        // A user-initiated play resets recovery; a retry from the reconnect
        // loop must not cancel the loop that issued it.
        if !isReconnectRestart {
            cancelReconnect()
            reconnectAttempt = 0
            autoResumeOnNetworkReturn = false
        }
        lastPlayArgs = (channel, streamURL, network)
        hasPlayedThisSession = false
        pausedAt = nil

        // Stop existing polling and observation
        trackPollTask?.cancel()
        statusObservation?.invalidate()
        statusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        metadataDelegate = nil

        // Release old player item before loading new one
        player?.replaceCurrentItem(with: nil)

        if player == nil {
            player = AVPlayer()
            player?.volume = isMuted ? 0 : volume
            timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
                let status = observed.timeControlStatus
                Task { @MainActor [weak self] in
                    self?.handleTimeControlChange(status)
                }
            }
        }
        // Re-apply the chosen route on every (re)start so reconnects and
        // quality changes keep playing to the same device.
        player?.audioOutputDeviceUniqueID = outputDeviceUID

        let sessionID = UUID()
        playbackSessionID = sessionID
        playbackError = nil
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
                    self?.handleItemFailure(error)
                default:
                    break
                }
            }
        }
        itemNotificationTokens = [
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleItemFailure(nil) }
            },
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleItemFailure(nil) }
            },
        ]
        installMetadataOutput(on: item, channelId: channel.id, channelName: channel.name, network: network, sessionID: sessionID)

        player?.replaceCurrentItem(with: item)
        player?.play()
        phase = .buffering

        currentChannel = channel
        currentNetwork = network
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
        startTrackPolling(channelId: channel.id, channelName: channel.name, network: network)
    }

    func pause() {
        cancelReconnect()
        autoResumeOnNetworkReturn = false
        player?.pause()
        isPlaying = false
        pausedAt = Date()
        phase = .paused
        trackPollTask?.cancel()
        trackPollTask = nil
        updateNowPlaying()
    }

    func resume() {
        guard currentChannel != nil else { return }
        // A live buffer paused for long (or a dead item) is stale or badly
        // behind — restart the stream instead of resuming into silence.
        let pausedTooLong = pausedAt.map { Date().timeIntervalSince($0) > 60 } ?? false
        if let args = lastPlayArgs,
           pausedTooLong || player?.currentItem == nil || player?.currentItem?.status == .failed {
            play(channel: args.channel, streamURL: args.url, network: args.network)
            return
        }
        pausedAt = nil
        player?.play()
        isPlaying = true
        phase = .buffering
        if let args = lastPlayArgs, trackPollTask == nil {
            startTrackPolling(channelId: args.channel.id, channelName: args.channel.name, network: args.network)
        }
        updateNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
        cancelReconnect()
        reconnectAttempt = 0
        autoResumeOnNetworkReturn = false
        lastPlayArgs = nil
        lastItemError = nil
        pausedAt = nil
        hasPlayedThisSession = false
        phase = .idle
        trackPollTask?.cancel()
        trackPollTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        removeItemNotificationObservers()
        metadataOutput = nil
        metadataDelegate = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        isPlaying = false
        playbackError = nil
        currentChannel = nil
        currentNetwork = nil
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
        isMuted = false // touching the slider unmutes, like the system slider
        player?.volume = newVolume
    }

    func toggleMute() {
        isMuted.toggle()
        player?.volume = isMuted ? 0 : volume
    }

    // MARK: - Output Routing

    /// CoreAudio device UID to play through; nil follows the system default.
    private(set) var outputDeviceUID: String?

    func setOutputDevice(uid: String?) {
        outputDeviceUID = uid
        player?.audioOutputDeviceUniqueID = uid
    }

    /// The underlying AVPlayer, exposed only for AVRoutePickerView (AirPlay).
    var routePickerPlayer: AVPlayer? { player }

    // MARK: - Stream Recovery

    private func handleTimeControlChange(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            hasPlayedThisSession = true
            reconnectAttempt = 0
            lastItemError = nil
            if isPlaying { phase = .playing }
        case .waitingToPlayAtSpecifiedRate:
            if isPlaying, reconnectTask == nil { phase = .buffering }
        case .paused:
            // A live stream dropping to .paused without user action is a stall.
            if isPlaying, reconnectTask == nil, phase == .playing {
                beginReconnect()
            }
        @unknown default:
            break
        }
    }

    private func handleItemFailure(_ errorDescription: String?) {
        guard isPlaying else { return }
        if let errorDescription { lastItemError = errorDescription }
        // An in-flight reconnect loop sees the failed item via waitUntilPlaying.
        guard reconnectTask == nil else { return }
        beginReconnect()
    }

    private func beginReconnect() {
        guard isPlaying, reconnectTask == nil, lastPlayArgs != nil else { return }
        // Startup failures (never audible this session) get a short ladder so
        // a bad key or missing subscription surfaces quickly; mid-stream drops
        // get the full one.
        let maxAttempts = hasPlayedThisSession ? Self.reconnectBackoff.count : 3
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(maxAttempts: maxAttempts)
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func runReconnectLoop(maxAttempts: Int) async {
        // A cancelled loop must not clear the slot — the canceller has already
        // reset it, possibly to a replacement task.
        defer { if !Task.isCancelled { reconnectTask = nil } }
        while reconnectAttempt < maxAttempts {
            let delay = Self.reconnectBackoff[min(reconnectAttempt, Self.reconnectBackoff.count - 1)]
            reconnectAttempt += 1
            phase = .reconnecting(attempt: reconnectAttempt)
            log.error("RECONNECT: attempt \(self.reconnectAttempt, privacy: .public)/\(maxAttempts, privacy: .public) in \(delay, privacy: .public)s")
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, isPlaying, let args = lastPlayArgs else { return }

            isReconnectRestart = true
            play(channel: args.channel, streamURL: args.url, network: args.network)
            isReconnectRestart = false
            phase = .reconnecting(attempt: reconnectAttempt)

            if await waitUntilPlaying(timeout: 15) {
                log.error("RECONNECT: recovered")
                return
            }
            guard !Task.isCancelled, isPlaying else { return }
        }

        log.error("RECONNECT: giving up after \(self.reconnectAttempt, privacy: .public) attempts")
        isPlaying = false
        phase = .failed
        autoResumeOnNetworkReturn = true
        playbackError = lastItemError ?? "Stream connection lost"
        updateNowPlaying()
    }

    private func waitUntilPlaying(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled || !isPlaying { return false }
            if player?.timeControlStatus == .playing { return true }
            if player?.currentItem?.status == .failed { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Called by PlaybackRecovery when the network path becomes satisfied.
    func networkPathRestored() {
        if isPlaying, isRecovering {
            reconnectAttempt = 0
            cancelReconnect()
            beginReconnect()
        } else if phase == .failed, autoResumeOnNetworkReturn, let args = lastPlayArgs {
            autoResumeOnNetworkReturn = false
            play(channel: args.channel, streamURL: args.url, network: args.network)
        }
    }

    /// Called by PlaybackRecovery after system wake if playback was active.
    /// A slept live-stream item is never trustworthy — always restart.
    func restartAfterWake() {
        guard isPlaying, let args = lastPlayArgs else { return }
        cancelReconnect()
        reconnectAttempt = 0
        play(channel: args.channel, streamURL: args.url, network: args.network)
    }

    private func removeItemNotificationObservers() {
        for token in itemNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        itemNotificationTokens = []
    }

    // MARK: - Now Playing Info Center

    private func updateNowPlaying() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTrack?.title ?? currentChannel?.name ?? "DIBar"
        info[MPMediaItemPropertyArtist] = currentTrack?.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentNetwork?.displayName ?? currentChannel?.name ?? "DIBar"
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

        // ◀◀/▶▶ media keys step through favorite channels (wired by AppState)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNextTrack?()
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPreviousTrack?()
            return .success
        }
    }

    // MARK: - Track Polling

    private func startTrackPolling(channelId: Int, channelName: String, network: Network) {
        trackPollTask = Task { [weak self] in
            await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName, network: network)

            while !Task.isCancelled {
                if let remaining = self?.apiTimeRemaining, remaining > 0, remaining < 30 {
                    // Near track end — sleep until track_end + 1s
                    log.error("POLL: sleeping \(remaining + 1, privacy: .public)s (track_end+1, remaining=\(remaining, privacy: .public))")
                    try? await Task.sleep(for: .seconds(remaining + 1))
                    guard !Task.isCancelled, self != nil else { break }

                    let oldIdentity = self?.apiTrackIdentity
                    await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName, network: network)

                    // Retry at +3s, +5s, +7s, +9s if API hasn't updated
                    if self?.apiTrackIdentity == oldIdentity {
                        for attempt in 1...4 {
                            let offset = 1 + attempt * 2 // +3, +5, +7, +9
                            log.error("POLL: retry \(attempt, privacy: .public)/4 (track_end+\(offset, privacy: .public)s)")
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled, self != nil else { break }
                            await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName, network: network)
                            if self?.apiTrackIdentity != oldIdentity { break }
                        }
                    }
                } else {
                    // Normal poll
                    log.error("POLL: sleeping \(self?.normalPollIntervalSeconds ?? 10, privacy: .public)s (apiTimeRemaining=\(self?.apiTimeRemaining?.description ?? "nil", privacy: .public))")
                    try? await Task.sleep(for: .seconds(self?.normalPollIntervalSeconds ?? 10))
                    guard !Task.isCancelled, self != nil else { break }
                    await self?.fetchAndUpdateTrack(channelId: channelId, channelName: channelName, network: network)
                }
            }
        }
    }

    private func fetchAndUpdateTrack(channelId: Int, channelName: String, network: Network) async {
        guard let item = try? await DIClient.fetchCurrentTrack(channelId: channelId, network: network) else { return }

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
            // Fuzzy match: ICY titles carry remix suffixes and quote variants
            // the API's canonical name lacks. On a match, the API's names win
            // (canonical identity) while ICY keeps owning timing.
            if TrackMatching.sameSong(
                artistA: apiArtist, titleA: apiTitle,
                artistB: nextTrack.artist, titleB: nextTrack.title
            ) {
                nextTrack = NowPlaying(
                    channelName: channelName,
                    artist: apiArtist.isEmpty ? nextTrack.artist : apiArtist,
                    title: apiTitle.isEmpty ? nextTrack.title : apiTitle,
                    trackId: item.trackId ?? nextTrack.trackId,
                    artURL: artURL ?? nextTrack.artURL,
                    duration: apiDuration,
                    startedAt: audibleStartedAt ?? nextTrack.startedAt,
                    elapsedOverride: nil,
                    upVotes: upVotes,
                    downVotes: downVotes
                )
                shouldUpdateTrack = true
            } else if apiLogicalKey != nil, currentLogicalKey != nil {
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
            // Same fuzzy test: the freeze holds while the API is on the next
            // song (different title), and lifts if it flaps back to ours.
            if TrackMatching.sameSong(
                artistA: apiArtist, titleA: apiTitle,
                artistB: nextTrack.artist, titleB: nextTrack.title
            ) {
                nextTrack = NowPlaying(
                    channelName: channelName,
                    artist: apiArtist.isEmpty ? nextTrack.artist : apiArtist,
                    title: apiTitle.isEmpty ? nextTrack.title : apiTitle,
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

    private func installMetadataOutput(on item: AVPlayerItem, channelId: Int, channelName: String, network: Network, sessionID: UUID) {
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        let delegate = StreamMetadataDelegate(
            owner: self,
            channelId: channelId,
            channelName: channelName,
            network: network,
            sessionID: sessionID
        )

        output.setDelegate(delegate, queue: DispatchQueue(label: "com.dibar.metadata"))
        // ICY titles arrive as timed metadata; 0.5s of delivery latency is
        // imperceptible and halves the delegate wakeups of the old 0.15s.
        output.advanceIntervalForDelegateInvocation = 0.5
        item.add(output)

        metadataOutput = output
        metadataDelegate = delegate
    }

    fileprivate func handleTimedMetadata(
        _ groups: [AVTimedMetadataGroup],
        channelId: Int,
        channelName: String,
        network: Network,
        sessionID: UUID
    ) async {
        guard sessionID == playbackSessionID else { return }

        for group in groups {
            for item in group.items {
                guard let streamTitle = await extractIcyStreamTitle(from: item) else { continue }
                await handleIcyStreamTitle(streamTitle, channelId: channelId, channelName: channelName, network: network, sessionID: sessionID)
                return
            }
        }
    }

    private func handleIcyStreamTitle(_ streamTitle: String, channelId: Int, channelName: String, network: Network, sessionID: UUID) async {
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
            await fetchAndUpdateTrack(channelId: channelId, channelName: channelName, network: network)
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
        await fetchAndUpdateTrack(channelId: channelId, channelName: channelName, network: network)
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
        currentTrack?.elapsedSeconds(at: now) ?? 0
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
        return await ArtCache.image(for: sized)
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
    let network: Network
    let sessionID: UUID

    init(owner: AudioPlayer, channelId: Int, channelName: String, network: Network, sessionID: UUID) {
        self.owner = owner
        self.channelId = channelId
        self.channelName = channelName
        self.network = network
        self.sessionID = sessionID
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        Task { [weak owner] in
            await owner?.handleTimedMetadata(groups, channelId: channelId, channelName: channelName, network: network, sessionID: sessionID)
        }
    }
}

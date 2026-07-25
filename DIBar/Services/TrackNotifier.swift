import AppKit
import Observation
import UserNotifications
import os

private let log = Logger(subsystem: "com.dibar", category: "TrackNotifier")

/// Posts a macOS notification when the song changes, by diffing a
/// once-per-second snapshot of the player's public state — the same passive
/// pattern as HistoryRecorder, no hooks in the timing engine.
@MainActor
final class TrackNotifier: NSObject {
    private let player: AudioPlayer
    private var timer: Timer?
    private var enabled = false
    private var isStarted = false

    /// Set from the app delegate so no banner fires while the popover is open.
    var popoverIsVisible = false

    private var lastIdentityToken: String?
    private var lastChannelId: Int?
    private var channelSwitchedAt: Date?
    private var sessionHasNotifiableTrack = false
    private var pendingPost: Task<Void, Never>?
    private var pendingAnnounce: Task<Void, Never>?

    init(player: AudioPlayer) {
        self.player = player
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        syncTimerToPlayback()
        observePlayback()
    }

    func setEnabled(_ isEnabled: Bool) {
        guard enabled != isEnabled else { return }
        enabled = isEnabled
        if isEnabled {
            // Seed the diff state so enabling mid-song never fires a stale
            // notification for changes that happened while disabled.
            lastChannelId = player.currentChannel?.id
            lastIdentityToken = player.currentTrackIdentityToken
        } else {
            pendingPost?.cancel()
            pendingPost = nil
        }
        syncTimerToPlayback()
    }

    /// The song-change diff only matters while notifications are enabled and
    /// the player is playing; otherwise the timer goes quiet. Channel-switch
    /// announcements are task-driven and unaffected.
    private func observePlayback() {
        withObservationTracking {
            _ = player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncTimerToPlayback()
                self.observePlayback()
            }
        }
    }

    private func syncTimerToPlayback() {
        guard isStarted else { return }
        if enabled && player.isPlaying {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer?.tolerance = 0.3
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Requests permission; calls back with whether notifications may be shown.
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void) {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
            await completion(granted)
        }
    }

    // MARK: - Tick

    private func tick() {
        let channelId = player.currentChannel?.id
        let token = player.currentTrackIdentityToken

        if channelId != lastChannelId {
            // New channel session: never notify for the track already playing
            // when the user just picked the station (they're looking at it).
            lastChannelId = channelId
            channelSwitchedAt = Date()
            sessionHasNotifiableTrack = false
            pendingPost?.cancel()
            pendingPost = nil
            lastIdentityToken = token
            return
        }

        guard token != lastIdentityToken else { return }
        let previousToken = lastIdentityToken
        lastIdentityToken = token

        // Reconnects and quality restarts reset the token to nil and re-seed;
        // treat nil→token like a session start, not a song change.
        guard token != nil else { return }
        if previousToken == nil, !sessionHasNotifiableTrack {
            sessionHasNotifiableTrack = true
            return
        }
        sessionHasNotifiableTrack = true

        guard enabled, player.isPlaying else { return }
        if let switchedAt = channelSwitchedAt, Date().timeIntervalSince(switchedAt) < 10 { return }
        if popoverIsVisible { return }

        // Settle before posting: rapid ICY flaps cancel the previous post, and
        // the delay gives the artwork a chance to arrive for the attachment.
        pendingPost?.cancel()
        pendingPost = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.postCurrentTrack()
        }
    }

    // MARK: - Channel-switch announcements

    /// Banner for a hotkey-driven channel/site switch: "Site · Channel" plus
    /// the playing song. Streams deliver ICY metadata a beat after the switch,
    /// so wait briefly for it; post without the song after ~4s. Gated by its
    /// own Settings toggle in AppState, independent of `enabled`.
    func announceSwitch() {
        log.info("announceSwitch: scheduled")
        pendingAnnounce?.cancel()
        pendingAnnounce = Task { [weak self] in
            for _ in 0..<8 {
                guard let self, !Task.isCancelled else { return }
                if self.realTrackParts != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, !Task.isCancelled else {
                log.info("announceSwitch: cancelled before post")
                return
            }
            self.postSwitchBanner()
        }
    }

    private func postSwitchBanner() {
        // No popover gate: this is feedback for an explicit user action
        guard let network = player.currentNetwork,
              let channel = player.currentChannel
        else {
            log.info("announceSwitch: skipped, no channel loaded")
            return
        }
        log.info("announceSwitch: posting \(network.displayName, privacy: .public) · \(channel.name, privacy: .public) (track: \(self.realTrackParts != nil, privacy: .public))")

        let content = UNMutableNotificationContent()
        content.title = "\(network.displayName) · \(channel.name)"
        if let parts = realTrackParts {
            content.subtitle = [parts.artist, parts.title]
                .filter { !$0.isEmpty }
                .joined(separator: " – ")
        }
        content.sound = nil
        if let attachment = artworkAttachment() {
            content.attachments = [attachment]
        }

        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.add(UNNotificationRequest(
            identifier: "switch-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    /// The current track's trimmed artist/title, or nil while the stream is
    /// still warming up (placeholder or empty metadata).
    private var realTrackParts: (artist: String, title: String)? {
        guard let track = player.currentTrack else { return nil }
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        let title = track.title.trimmingCharacters(in: .whitespaces)
        guard !(artist.isEmpty && title.isEmpty), title != "Loading..." else { return nil }
        return (artist, title)
    }

    private func postCurrentTrack() {
        guard enabled, player.isPlaying, !popoverIsVisible,
              let track = player.currentTrack
        else { return }
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        let title = track.title.trimmingCharacters(in: .whitespaces)
        guard !(artist.isEmpty && title.isEmpty), title != "Loading..." else { return }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? artist : title
        if !artist.isEmpty, !title.isEmpty {
            content.subtitle = artist
        }
        if let network = player.currentNetwork, let channel = player.currentChannel {
            content.body = "\(network.displayName) · \(channel.name)"
        }
        content.sound = nil

        if let attachment = artworkAttachment() {
            content.attachments = [attachment]
        }

        let center = UNUserNotificationCenter.current()
        // Radio would otherwise pile a notification per song into Notification
        // Center — keep only the current one around.
        center.removeAllDeliveredNotifications()
        center.add(UNNotificationRequest(
            identifier: "track-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    private func artworkAttachment() -> UNNotificationAttachment? {
        guard let image = player.currentArtImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dibar-art-\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: url)
            // The attachment takes ownership of (moves) the file — no cleanup.
            return try UNNotificationAttachment(identifier: "artwork", url: url)
        } catch {
            log.error("artwork attachment failed: \(error.localizedDescription)")
            return nil
        }
    }
}

extension TrackNotifier: UNUserNotificationCenterDelegate {
    /// Banners must show even when DIBar is the active app — as an agent app
    /// it frequently is, whenever the panel has key status.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}

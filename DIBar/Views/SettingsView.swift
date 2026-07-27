import SwiftUI
import ServiceManagement

/// Content of the standalone "DIBar Settings" window.
struct SettingsWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var launchAtLogin: Bool?
    @State private var isUpdatingLaunchAtLogin = false
    @State private var showLogoutConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            settingsRow("Quality") {
                qualityMenu
            }

            Divider()

            settingsRow("Menu bar") {
                HStack(spacing: 4) {
                    ToggleChip(title: "play/pause", systemImage: "playpause.fill", isOn: Bindable(appState).menuBarShowPlayState)
                    ToggleChip(title: "Site", isOn: Bindable(appState).menuBarShowSite)
                    ToggleChip(title: "Channel", isOn: Bindable(appState).menuBarShowStation)
                    ToggleChip(title: "Artist", isOn: Bindable(appState).menuBarShowArtist)
                    ToggleChip(title: "Song", isOn: Bindable(appState).menuBarShowSong)
                }
            }

            Image(nsImage: MenuBarLabelRenderer.labelImage(
                line1: appState.menuBarPreviewLine1,
                line2: appState.menuBarPreviewLine2,
                glyph: previewGlyph
            ))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)

            Divider()

            settingsRow("Launch at login") {
                if launchAtLogin == nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Toggle("", isOn: launchAtLoginBinding)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(isUpdatingLaunchAtLogin)
                }
            }

            Divider()

            settingsRow("Global shortcuts") {
                Toggle("", isOn: Bindable(appState).globalHotkeysEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .help("System-wide keyboard shortcuts that work in any app.")

            VStack(alignment: .leading, spacing: 5) {
                shortcutRow(label: "play/pause") {
                    KeyCap("⌃"); KeyCap("⌥"); KeyCap("⌘"); KeyCap("P")
                    keySeparator("or")
                    KeyCap(systemImage: "playpause.fill")
                }
                shortcutRow(label: "prev/next fav channel") {
                    KeyCap("⌃"); KeyCap("⌥"); KeyCap("⌘"); KeyCap("←")
                    keySeparator("/")
                    KeyCap("→")
                    keySeparator("or")
                    KeyCap(systemImage: "backward.fill")
                    keySeparator("/")
                    KeyCap(systemImage: "forward.fill")
                }
                shortcutRow(label: "prev/next site") {
                    KeyCap("⌃"); KeyCap("⌥"); KeyCap("⌘"); KeyCap("↑")
                    keySeparator("/")
                    KeyCap("↓")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            Divider()

            settingsRow("Notification on song change") {
                Toggle("", isOn: Bindable(appState).notifyTrackChanges)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .help("Shows a notification with the artist and song each time the track changes while the popover is closed.")

            settingsRow("Notification on channel switch") {
                Toggle("", isOn: Bindable(appState).notifySwitchChanges)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .help("Shows the site, channel, and song when you switch channels with a keyboard shortcut.")

            if let hint = appState.notifyPermissionHint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            Divider()

            settingsRow("Sleep timer quits DIBar") {
                Toggle("", isOn: Bindable(appState).sleepTimerQuitsApp)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .help("When the sleep timer fires, quit DIBar entirely instead of just pausing playback.")

            Divider()

            settingsRow("Save song history (on this Mac)") {
                Toggle("", isOn: Bindable(appState).saveListeningHistory)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .help("Remembers the songs and channels you listen to in a file on this Mac, so DIBar can show your listening stats. Nothing is sent anywhere.")

            Divider()

            scrobblingSection

            Divider()

            Button {
                openURL(appState.subscriptionURL)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.membershipHeaderLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(appState.membershipDetailLine)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            settingsRow("DI.FM account") {
                HStack(spacing: 8) {
                    if let email = appState.accountEmail {
                        Text(email)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HoverTextButton(title: "Log Out", tint: .red) {
                        showLogoutConfirmation = true
                    }
                }
            }
        }
        .frame(width: 320)
        .task {
            guard launchAtLogin == nil else { return }
            launchAtLogin = await Self.readLaunchAtLoginStatus()
        }
        .alert("Log out of DI.FM?", isPresented: $showLogoutConfirmation) {
            Button("Log Out", role: .destructive) {
                appState.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let email = appState.accountEmail {
                Text("You're signed in as \(email). You'll need to sign in again to listen.")
            } else {
                Text("You'll need to sign in with your account again to listen.")
            }
        }
    }

    // MARK: - Launch at Login

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin ?? false },
            set: updateLaunchAtLogin
        )
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard !isUpdatingLaunchAtLogin else { return }
        launchAtLogin = enabled
        isUpdatingLaunchAtLogin = true

        Task {
            let resolved = await Task.detached(priority: .userInitiated) {
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    return enabled
                } catch {
                    return SMAppService.mainApp.status == .enabled
                }
            }.value
            launchAtLogin = resolved
            isUpdatingLaunchAtLogin = false
        }
    }

    private static func readLaunchAtLoginStatus() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            SMAppService.mainApp.status == .enabled
        }.value
    }

    // MARK: - Scrobbling

    private var scrobblingSection: some View {
        VStack(spacing: 0) {
            // Last.fm — also feeds Airbuds (connect Last.fm inside Airbuds)
            settingsRow("Last.fm") {
                lastFMControl
            }
            .help("Sends the songs you listen to (at least half through, or 4 minutes) to your Last.fm profile. Apps like Airbuds can read them from there. Requires song history to stay on.")

            if let error = appState.scrobbler.connectionError {
                caption(error, color: .orange)
            } else if appState.scrobbler.lastFMNeedsReconnect {
                caption("Last.fm session expired — connect again", color: .orange)
            }
        }
    }

    @ViewBuilder
    private var lastFMControl: some View {
        let scrobbler = appState.scrobbler
        if !LastFMClient.isConfigured {
            Text("Requires an API key (see ScrobbleClients.swift)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else if let username = scrobbler.lastFMUsername, scrobbler.lastFMConnected {
            HStack(spacing: 8) {
                Text(username)
                    .font(.system(size: 11))
                HoverTextButton(title: "Disconnect", tint: .red) {
                    scrobbler.disconnectLastFM()
                }
            }
        } else if scrobbler.lastFMPendingToken != nil {
            Button("Finish connecting") {
                scrobbler.finishLastFMConnect()
            }
            .controlSize(.small)
        } else {
            Button("Connect…") {
                scrobbler.connectLastFM()
            }
            .controlSize(.small)
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(StreamQuality.allCases) { quality in
                Button {
                    guard appState.selectedQuality != quality else { return }
                    appState.selectedQuality = quality
                    Prefs.set(quality.rawValue, for: .quality)
                    appState.restartStreamForQualityChange()
                } label: {
                    // Every item reserves the checkmark slot so names align
                    let check = Text("\(Image(systemName: "checkmark"))")
                        .foregroundStyle(quality == appState.selectedQuality ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                    Text("\(check) \(quality.displayName)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(appState.selectedQuality.displayName)
                    .font(.system(size: 11))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .cursor(.pointingHand)
    }

    /// Glyph for the preview card: honors the chip, shows the real state when
    /// a station is loaded, and demonstrates "playing" as the idle placeholder.
    private var previewGlyph: MenuBarLabelRenderer.PlaybackGlyph {
        guard appState.menuBarShowPlayState else { return .none }
        if appState.audioPlayer.currentChannel != nil {
            return MenuBarLabelRenderer.glyph(for: appState.audioPlayer)
        }
        return .playing
    }

    /// One line of the shortcuts helper: keycaps left, action label right.
    private func shortcutRow(label: String, @ViewBuilder keys: () -> some View) -> some View {
        HStack(spacing: 3) {
            keys()
            Spacer(minLength: 8)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func keySeparator(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
    }

    /// Caption on the left, control flush right, uniform height and padding.
    private func settingsRow(_ caption: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            control()
        }
        .frame(minHeight: 22)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Key Cap

/// A single keyboard key rendered as a small rounded keycap.
private struct KeyCap: View {
    var label: String?
    var systemImage: String?

    init(_ label: String) { self.label = label }
    init(systemImage: String) { self.systemImage = systemImage }

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 7, weight: .semibold))
            } else {
                Text(label ?? "")
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
        .frame(minWidth: 12, minHeight: 11)
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3.5)
                .fill(.quaternary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3.5)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// MARK: - Toggle Chip

private struct ToggleChip: View {
    let title: String
    var systemImage: String? = nil
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: isOn ? .semibold : .regular))
                } else {
                    Text(title)
                        .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                }
            }
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.accentColor.opacity(isHovered ? 0.9 : 0), lineWidth: 1.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .help(isOn ? "Hide \(title.lowercased()) in the menu bar" : "Show \(title.lowercased()) in the menu bar")
    }
}

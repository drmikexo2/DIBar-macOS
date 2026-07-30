import SwiftUI
import Sparkle
import os

private let log = Logger(subsystem: "com.dibar", category: "App")
/// Update outcomes go to their own category: a stalled update is otherwise
/// indistinguishable from "no update available", since scheduled updates
/// install silently and never present a dialog.
private let updateLog = Logger(subsystem: "com.dibar", category: "Updates")

// The menu bar item is managed directly via NSStatusItem instead of
// MenuBarExtra: MenuBarExtra's label pipeline only renders single-line Text
// and static images, silently dropping dynamic NSImages, stacked views, and
// multi-line text — all needed for the two-line now-playing label.
@main
struct DIBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // `App` demands at least one Scene and Settings is the only one that
        // does not open a window at launch, so it stands in as a placeholder.
        // Its EmptyView is never shown: replacing the .appSettings group
        // detaches ⌘, from the placeholder and points it at the AppKit
        // settings window, which needs presentAuxiliaryWindow's LSUIElement
        // activation handling and closePanel's status-item bookkeeping.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    delegate.showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Borderless panels refuse key status by default; the search field needs it.
private final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            orderOut(nil)
        }
    }
}

/// Behind-window material shared by the panel base and the pinned section
/// headers: it samples only content behind the *window*, so a header strip
/// occludes rows sliding under it yet renders pixel-identical to the base
/// layer at the same screen rect — no double-tinted stripe like stacked
/// SwiftUI materials produce.
struct PanelMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        if cornerRadius > 0 {
            view.maskImage = .cornerMask(radius: cornerRadius)
        }
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The panel's rapidly changing presentation state is deliberately separate
/// from AppState. Speaker frames should invalidate only the indicator views,
/// not every consumer of the application's long-lived model.
@Observable
@MainActor
final class PanelPresentationState {
    var isVisible = false
    var speakerWaveFrame = 0
}

/// Long-lived UI state for a scheduled Sparkle update that DIBar is reminding
/// the user about without stealing focus from the foreground application.
@Observable
@MainActor
final class UpdatePresentationState {
    enum Phase: Equatable {
        case available(version: String)
        case recovering(version: String)
        case ready(version: String)
        case failed(version: String)

        var version: String {
            switch self {
            case .available(let version), .recovering(let version),
                 .ready(let version), .failed(let version):
                version
            }
        }

        var toolTip: String {
            switch self {
            case .available:
                "A DIBar update is available"
            case .recovering:
                "DIBar is finishing an update"
            case .ready:
                "Restart DIBar to finish updating"
            case .failed:
                "A DIBar update could not finish"
            }
        }
    }

    private(set) var phase: Phase?

    func showAvailable(version: String) {
        // A gentle reminder must not overwrite a more advanced or failed
        // state owned by DIBar's installation coordinator.
        guard phase == nil || isAvailable else { return }
        phase = .available(version: version)
    }

    func showRecovering(version: String) {
        phase = .recovering(version: version)
    }

    func showReady(version: String) {
        phase = .ready(version: version)
    }

    func showFailed(version: String) {
        phase = .failed(version: version)
    }

    func clearAvailable() {
        guard isAvailable else { return }
        phase = nil
    }

    func clear() {
        phase = nil
    }

    private var isAvailable: Bool {
        if case .available = phase { return true }
        return false
    }
}

enum SpeakerAnimationPolicy {
    static func shouldRun(
        isPanelVisible: Bool,
        isAudiblyPlaying: Bool,
        reduceMotion: Bool
    ) -> Bool {
        isPanelVisible && isAudiblyPlaying && !reduceMotion
    }
}

enum UpdateReminderPolicy {
    /// Near launch or after idle time, Sparkle can present its standard window
    /// in focus. Otherwise DIBar owns the reminder in its menu-bar UI.
    static func shouldLetSparklePresent(immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    static func shouldShowBadge(handleShowingUpdate: Bool, userInitiated: Bool) -> Bool {
        !handleShowingUpdate && !userInitiated
    }
}

enum UpdateInstallPolicy {
    static func canInstallAutomatically(
        isPlaying: Bool,
        isPanelVisible: Bool,
        isSettingsVisible: Bool,
        isHistoryVisible: Bool
    ) -> Bool {
        !isPlaying && !isPanelVisible && !isSettingsVisible && !isHistoryVisible
    }
}

/// Sparkle keeps a downloaded-but-uninstalled update only in memory
/// (`SPUUpdater._resumableUpdate`) and otherwise resumes solely by probing for
/// a still-running installer process. A restart between download and install
/// loses both, stranding a verified update in the cache until the next
/// scheduled check, which is 24 hours out. DIBar therefore records what was
/// staged and asks Sparkle to check again on the next launch.
enum PendingUpdatePolicy {
    /// Stop retrying after this many launches so a permanently failing install
    /// does not check on every launch forever.
    static let maxAttempts = 3

    static func shouldResume(
        pendingBuild: String?,
        pendingVersion: String?,
        runningBuild: String,
        runningVersion: String,
        attempts: Int
    ) -> Bool {
        guard hasPendingUpdate(pendingBuild: pendingBuild, pendingVersion: pendingVersion) else {
            return false
        }
        guard !didInstall(
            pendingBuild: pendingBuild,
            pendingVersion: pendingVersion,
            runningBuild: runningBuild,
            runningVersion: runningVersion
        ) else {
            return false
        }
        return attempts < maxAttempts
    }

    /// True once the staged build is the one actually running. The display
    /// version is a fallback for pending records made before build persistence
    /// was added.
    static func didInstall(
        pendingBuild: String?,
        pendingVersion: String?,
        runningBuild: String,
        runningVersion: String
    ) -> Bool {
        if let pendingBuild, !pendingBuild.isEmpty {
            return pendingBuild == runningBuild
        }
        guard let pendingVersion, !pendingVersion.isEmpty else { return false }
        return pendingVersion == runningVersion
    }

    static func hasPendingUpdate(pendingBuild: String?, pendingVersion: String?) -> Bool {
        pendingBuild?.isEmpty == false || pendingVersion?.isEmpty == false
    }

    /// `didAbortWithError` also fires for the ordinary "already up to date"
    /// outcome, which must not be logged as a failure.
    static func isReportableFailure(errorCode: Int) -> Bool {
        errorCode != Int(SUError.noUpdateError.rawValue)
    }
}

/// Removing MenuBarView from the hierarchy on close releases its SwiftUI
/// display graph and disconnects TimelineView and playback observations. The
/// tiny placeholder keeps the hosting controller valid without retaining the
/// expensive hidden panel.
private struct PanelRootView: View {
    @Environment(PanelPresentationState.self) private var presentation
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        Group {
            if presentation.isVisible {
                MenuBarView(
                    onOpenSettings: onOpenSettings,
                    onOpenHistory: onOpenHistory,
                    onCheckForUpdates: onCheckForUpdates
                )
            } else {
                Color.clear.frame(width: 320, height: 1)
            }
        }
        .background(PanelMaterial(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension NSImage {
    /// Stretchable rounded-rect mask; shapes both the blur region and the
    /// window shadow (the same mechanism NSPopover uses).
    static func cornerMask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency SPUStandardUserDriverDelegate,
                         SPUUpdaterDelegate {
    private struct PendingInstallation {
        let displayVersion: String
        let buildVersion: String
        let installNow: () -> Void
    }

    // Internal (not private) so DIBarApp+Debug.swift can drive the app.
    var appState: AppState!
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var panelTopLeft: NSPoint?
    private var lastLabelKey: String?
    private var speakerAnimationTimer: Timer?
    private let panelPresentation = PanelPresentationState()
    private let updatePresentation = UpdatePresentationState()
    private var pendingInstallation: PendingInstallation?
    private var isInstallingUpdate = false
    private var isRecoveringPendingUpdate = false

    // Sparkle owns the whole update pipeline (feed check, download, and the
    // out-of-sandbox install via its Installer XPC service). Starting it here
    // schedules the automatic background checks.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A pending update outranks automatic station restoration. AppState
        // still bootstraps account and channel data; only autoplay waits.
        appState = AppState(
            suppressAutomaticPlaybackRestore: shouldRecoverPendingUpdateAtLaunch()
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))

        // A plain panel, positioned once at open time, instead of NSPopover:
        // popovers permanently track their anchor, so a resizing status item
        // (live label updates) made the panel jump around mid-interaction.
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in
            self?.closePanel()
        }

        let hosting = NSHostingController(
            rootView: PanelRootView(
                onOpenSettings: { [weak self] in
                    self?.showSettingsWindow()
                },
                onOpenHistory: { [weak self] in
                    self?.showHistoryWindow()
                },
                onCheckForUpdates: { [weak self] in
                    self?.performUpdateAction()
                }
            )
                .environment(appState)
                .environment(panelPresentation)
                .environment(updatePresentation)
        )
        hosting.sizingOptions = .preferredContentSize
        panel.contentViewController = hosting

        // Content height changes (artwork expand, list collapse) resize the
        // window from its bottom edge; re-pin the top-left so the panel only
        // ever grows/shrinks downward from where it opened.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible, let topLeft = self.panelTopLeft else { return }
                // Skip the re-pin when the origin is already right — a second
                // setFrame per layout pass feeds back into window layout.
                let target = NSPoint(x: topLeft.x, y: topLeft.y - self.panel.frame.height)
                guard self.panel.frame.origin != target else { return }
                self.panel.setFrameTopLeftPoint(topLeft)
            }
        }

        // Transient behavior: close when the panel stops being key — unless
        // focus moved to a child window of ours (e.g. the site dropdown).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                if let key = NSApp.keyWindow, key !== self.panel { return }
                self.closePanel()
            }
        }

        startLabelObservation()
        startSpeakerAnimationObservation()
        startUpdateInstallObservation()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncSpeakerAnimationClock() }
        }

        setupDebugNotifications()

        // Start Sparkle only after DIBar's UI and idle observers exist; a local
        // feed can finish quickly enough to call the delegate during launch.
        _ = updaterController
        resumePendingUpdateIfNeeded()
    }

    // MARK: - Auxiliary windows

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func showSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsWindowView(onCheckForUpdates: { [weak self] in
                    self?.performUpdateAction()
                }).environment(appState)
            ))
            window.title = "DIBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            observeUpdateWindowClosing(window)
        }
        presentAuxiliaryWindow(settingsWindow!)
    }

    func showHistoryWindow() {
        if historyWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: HistoryWindowView().environment(appState)
            ))
            window.title = "Listening History"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 480))
            window.center()
            historyWindow = window
            observeUpdateWindowClosing(window)
        }
        presentAuxiliaryWindow(historyWindow!)
    }

    private func observeUpdateWindowClosing(_ window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installPendingUpdateIfIdle() }
        }
    }

    /// The status panel is already key and DIBar is active for normal clicks.
    /// Keep that activation continuous: promote the destination first, then
    /// remove the panel. Debug/external invocations may need explicit
    /// activation, but it must happen before ordering the destination window.
    private func presentAuxiliaryWindow(_ window: NSWindow) {
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            // Activation of an LSUIElement app can complete seconds later.
            // This explicit user/debug request should still become visible
            // immediately; it will become key as activation catches up.
            window.orderFrontRegardless()
            window.makeKey()
        }
        if panel.isVisible {
            closePanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSpeakerAnimationClock()
        appState?.historyRecorder.appWillTerminate()
    }

    // MARK: - Sparkle reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        UpdateReminderPolicy.shouldLetSparklePresent(immediateFocus: immediateFocus)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard UpdateReminderPolicy.shouldShowBadge(
            handleShowingUpdate: handleShowingUpdate,
            userInitiated: state.userInitiated
        ) else { return }
        updatePresentation.showAvailable(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updatePresentation.clearAvailable()
    }

    func standardUserDriverWillFinishUpdateSession() {
        updatePresentation.clearAvailable()
    }

    // MARK: - Update outcomes

    private static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private static var runningBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private func shouldRecoverPendingUpdateAtLaunch() -> Bool {
        PendingUpdatePolicy.shouldResume(
            pendingBuild: Prefs.string(.pendingUpdateBuild),
            pendingVersion: Prefs.string(.pendingUpdateVersion),
            runningBuild: Self.runningBuild,
            runningVersion: Self.runningVersion,
            attempts: Prefs.int(.pendingUpdateAttempts) ?? 0
        )
    }

    /// An update that finished downloading but never installed leaves Sparkle
    /// with nothing to resume from after a relaunch, so ask it to check again
    /// now rather than waiting out the 24-hour schedule.
    private func resumePendingUpdateIfNeeded() {
        let pendingBuild = Prefs.string(.pendingUpdateBuild)
        let pendingVersion = Prefs.string(.pendingUpdateVersion)
        guard PendingUpdatePolicy.hasPendingUpdate(
            pendingBuild: pendingBuild,
            pendingVersion: pendingVersion
        ) else {
            return
        }

        if PendingUpdatePolicy.didInstall(
            pendingBuild: pendingBuild,
            pendingVersion: pendingVersion,
            runningBuild: Self.runningBuild,
            runningVersion: Self.runningVersion
        ) {
            updateLog.info(
                "Update to \(Self.runningVersion, privacy: .public) (\(Self.runningBuild, privacy: .public)) installed; clearing pending state"
            )
            clearPendingUpdate()
            return
        }

        let attempts = Prefs.int(.pendingUpdateAttempts) ?? 0
        guard PendingUpdatePolicy.shouldResume(
            pendingBuild: pendingBuild,
            pendingVersion: pendingVersion,
            runningBuild: Self.runningBuild,
            runningVersion: Self.runningVersion,
            attempts: attempts
        ) else {
            let displayVersion = pendingVersion ?? pendingBuild ?? "latest"
            updateLog.error(
                "Update \(displayVersion, privacy: .public) still not installed after \(attempts) attempts; waiting for manual retry"
            )
            updatePresentation.showFailed(version: displayVersion)
            appState.releaseAutomaticPlaybackRestore()
            return
        }

        let displayVersion = pendingVersion ?? pendingBuild ?? "latest"
        Prefs.set(attempts + 1, for: .pendingUpdateAttempts)
        isRecoveringPendingUpdate = true
        updatePresentation.showRecovering(version: displayVersion)
        updateLog.info(
            "Update \(displayVersion, privacy: .public) was downloaded but not installed; rechecking (attempt \(attempts + 1))"
        )
        // The background variant on purpose. checkForUpdates(_:) is the
        // user-initiated path and Sparkle rejects it here with
        // "sessionInProgress == YES", because its own cycle is still running
        // this early in launch. The background check restages the update and
        // hands us an immediate-install block via willInstallUpdateOnQuit.
        updaterController.updater.checkForUpdatesInBackground()
    }

    private func clearPendingUpdate() {
        Prefs.set(nil, for: .pendingUpdateVersion)
        Prefs.set(nil, for: .pendingUpdateBuild)
        Prefs.set(0, for: .pendingUpdateAttempts)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateLog.info("Found update \(item.displayVersionString, privacy: .public)")
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard choice == .skip else { return }
        updateLog.info("User skipped \(item.displayVersionString, privacy: .public); clearing DIBar pending state")
        pendingInstallation = nil
        isRecoveringPendingUpdate = false
        isInstallingUpdate = false
        clearPendingUpdate()
        updatePresentation.clear()
        appState.releaseAutomaticPlaybackRestore()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        updateLog.info("No update available: \(error.localizedDescription, privacy: .public)")
        // Nothing is staged any more, so a recorded pending version is stale.
        clearPendingUpdate()
        if isRecoveringPendingUpdate {
            isRecoveringPendingUpdate = false
            updatePresentation.clear()
            appState.releaseAutomaticPlaybackRestore()
        }
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        updateLog.error(
            "Failed to download \(item.displayVersionString, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        handleUpdateFailure()
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        updateLog.info("Extracted \(item.displayVersionString, privacy: .public); awaiting install")
        Prefs.set(item.displayVersionString, for: .pendingUpdateVersion)
        Prefs.set(item.versionString, for: .pendingUpdateBuild)
        // Staging worked, so the pipeline is healthy and any further delay is
        // no longer a recovery-check failure.
        Prefs.set(0, for: .pendingUpdateAttempts)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        updateLog.info("Installing \(item.displayVersionString, privacy: .public)")
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        // Critical updates deliberately use Sparkle's standard immediate
        // presentation and escalation rules.
        guard !item.isCriticalUpdate else {
            if isRecoveringPendingUpdate {
                isRecoveringPendingUpdate = false
                updatePresentation.clear()
                appState.releaseAutomaticPlaybackRestore()
            }
            updateLog.info("\(item.displayVersionString, privacy: .public) is critical; leaving presentation to Sparkle")
            return false
        }

        let recovered = isRecoveringPendingUpdate
        isRecoveringPendingUpdate = false
        updateLog.info(
            "\(item.displayVersionString, privacy: .public) \(recovered ? "restaged" : "staged"); DIBar owns restart timing"
        )
        DispatchQueue.main.async { [weak self] in
            self?.acceptPendingInstallation(
                displayVersion: item.displayVersionString,
                buildVersion: item.versionString,
                installNow: immediateInstallationBlock,
                recovered: recovered
            )
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        guard PendingUpdatePolicy.isReportableFailure(errorCode: (error as NSError).code) else {
            updateLog.info("Update cycle ended: \(error.localizedDescription, privacy: .public)")
            return
        }
        updateLog.error("Update aborted: \(error.localizedDescription, privacy: .public)")
        handleUpdateFailure()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard let error else { return }
        guard PendingUpdatePolicy.isReportableFailure(errorCode: (error as NSError).code) else { return }
        updateLog.error("Update cycle failed: \(error.localizedDescription, privacy: .public)")
        handleUpdateFailure()
    }

    private func acceptPendingInstallation(
        displayVersion: String,
        buildVersion: String,
        installNow: @escaping () -> Void,
        recovered: Bool
    ) {
        pendingInstallation = PendingInstallation(
            displayVersion: displayVersion,
            buildVersion: buildVersion,
            installNow: installNow
        )
        // Close the last possible race with bootstrap: once installation has
        // been accepted, a saved station may not start before the next run loop.
        appState.suppressAutomaticPlaybackRestore()

        if installPendingUpdateIfIdle() {
            updateLog.info(
                "\(displayVersion, privacy: .public) \(recovered ? "recovered and " : "")installing while DIBar is idle"
            )
        } else {
            updateLog.info("\(displayVersion, privacy: .public) ready; waiting for DIBar to become idle")
            updatePresentation.showReady(version: displayVersion)
        }
    }

    @discardableResult
    private func installPendingUpdateIfIdle() -> Bool {
        guard pendingInstallation != nil, !isInstallingUpdate else { return false }

#if DEBUG
        // The end-to-end smoke test needs to strand a real staged update before
        // simulating reboot. Production builds never contain this launch hook.
        if ProcessInfo.processInfo.arguments.contains("--dibar-update-smoke-busy") {
            return false
        }
#endif

        guard UpdateInstallPolicy.canInstallAutomatically(
            isPlaying: appState.audioPlayer.isPlaying,
            isPanelVisible: panel?.isVisible == true,
            isSettingsVisible: settingsWindow?.isVisible == true,
            isHistoryVisible: historyWindow?.isVisible == true
        ) else {
            return false
        }

        installPendingUpdate()
        return true
    }

    private func installPendingUpdate() {
        guard let pendingInstallation, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updatePresentation.clear()
        updateLog.info(
            "Installing \(pendingInstallation.displayVersion, privacy: .public) (\(pendingInstallation.buildVersion, privacy: .public)) and relaunching"
        )
        pendingInstallation.installNow()
    }

    private func performUpdateAction() {
        if pendingInstallation != nil {
            installPendingUpdate()
            return
        }

        if case .failed = updatePresentation.phase {
            Prefs.set(0, for: .pendingUpdateAttempts)
            updatePresentation.clear()
        }
        updaterController.checkForUpdates(nil)
    }

    private func handleUpdateFailure() {
        if let pendingInstallation {
            self.pendingInstallation = nil
            isInstallingUpdate = false
            appState.releaseAutomaticPlaybackRestore()
            updatePresentation.showFailed(version: pendingInstallation.displayVersion)
            return
        }

        guard isRecoveringPendingUpdate else { return }
        isRecoveringPendingUpdate = false
        appState.releaseAutomaticPlaybackRestore()

        let attempts = Prefs.int(.pendingUpdateAttempts) ?? 0
        if attempts >= PendingUpdatePolicy.maxAttempts {
            let version = Prefs.string(.pendingUpdateVersion)
                ?? Prefs.string(.pendingUpdateBuild)
                ?? "latest"
            updatePresentation.showFailed(version: version)
        } else {
            updatePresentation.clear()
        }
    }

    @objc func togglePanel(_ sender: Any?) {
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        panelPresentation.isVisible = true
        panel.contentView?.layoutSubtreeIfNeeded()
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        panel.layoutIfNeeded()
        let panelWidth = max(panel.frame.width, 320)
        var x = buttonFrame.midX - panelWidth / 2
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - panelWidth - 8)
        }

        // Chosen once; never recomputed while open — the panel stays put no
        // matter how the status item resizes underneath.
        let topLeft = NSPoint(x: x, y: buttonFrame.minY - 6)
        panelTopLeft = topLeft
        panel.setFrameTopLeftPoint(topLeft)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statusItem.button?.highlight(true)
        appState.trackNotifier.popoverIsVisible = true
        syncSpeakerAnimationClock()
    }

    private func closePanel() {
        stopSpeakerAnimationClock()
        panelPresentation.isVisible = false
        panelTopLeft = nil
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        appState.trackNotifier.popoverIsVisible = false
        installPendingUpdateIfIdle()
    }

    // MARK: - Update idleness

    /// Playback may stop after an update was staged. Re-arm Observation after
    /// every change so a deferred update installs as soon as DIBar is safe.
    private func startUpdateInstallObservation() {
        withObservationTracking {
            _ = appState.audioPlayer.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.installPendingUpdateIfIdle()
                self.startUpdateInstallObservation()
            }
        }
    }

    // MARK: - Speaker animation

    /// Playback phase and mute state can change while the panel remains open.
    /// Re-arm Observation after each change and keep the single shared clock
    /// exactly in sync with whether an audible indicator can be onscreen.
    private func startSpeakerAnimationObservation() {
        withObservationTracking {
            _ = appState.audioPlayer.phase
            _ = appState.audioPlayer.isMuted
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncSpeakerAnimationClock()
                self.startSpeakerAnimationObservation()
            }
        }
    }

    private func syncSpeakerAnimationClock() {
        let shouldRun = SpeakerAnimationPolicy.shouldRun(
            isPanelVisible: panelPresentation.isVisible && panel.isVisible,
            isAudiblyPlaying: appState.audioPlayer.isAudiblyPlaying,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        guard shouldRun else {
            stopSpeakerAnimationClock()
            return
        }
        guard speakerAnimationTimer == nil else { return }

        panelPresentation.speakerWaveFrame = 0
        let timer = Timer(
            timeInterval: SpeakerIndicatorPresentation.waveFrameInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.speakerAnimationTimer != nil else { return }
                self.panelPresentation.speakerWaveFrame =
                    (self.panelPresentation.speakerWaveFrame + 1)
                    % SpeakerIndicatorPresentation.waveFrameCount
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        speakerAnimationTimer = timer
    }

    private func stopSpeakerAnimationClock() {
        speakerAnimationTimer?.invalidate()
        speakerAnimationTimer = nil
    }

    // Re-render the label whenever any observable state it reads changes;
    // no polling. The change key still dedups redraws when a tracked write
    // doesn't alter the rendered text/glyph.
    private func startLabelObservation() {
        withObservationTracking {
            refreshLabel()
        } onChange: { [weak self] in
            Task { @MainActor in self?.startLabelObservation() }
        }
    }

    private func refreshLabel() {
        guard let button = statusItem.button else { return }
        let line1 = appState.menuBarLine1
        let line2 = appState.menuBarLine2
        let glyph = appState.menuBarShowPlayState
            ? MenuBarLabelRenderer.glyph(for: appState.audioPlayer)
            : MenuBarLabelRenderer.PlaybackGlyph.none
        let updatePhase = updatePresentation.phase
        let showsUpdateBadge = updatePhase != nil
        let key = "\(line1 ?? "")|\(line2 ?? "")|\(glyph)|\(String(describing: updatePhase))"
        guard key != lastLabelKey else { return }
        lastLabelKey = key
        button.image = MenuBarLabelRenderer.labelImage(
            line1: line1,
            line2: line2,
            glyph: glyph,
            showsUpdateBadge: showsUpdateBadge
        )
        button.toolTip = updatePhase?.toolTip
    }
}

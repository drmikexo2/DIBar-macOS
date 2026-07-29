import SwiftUI
import os

private let log = Logger(subsystem: "com.dibar", category: "App")

// The menu bar item is managed directly via NSStatusItem instead of
// MenuBarExtra: MenuBarExtra's label pipeline only renders single-line Text
// and static images, silently dropping dynamic NSImages, stacked views, and
// multi-line text — all needed for the two-line now-playing label.
@main
struct DIBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            EmptyView()
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

enum SpeakerAnimationPolicy {
    static func shouldRun(
        isPanelVisible: Bool,
        isAudiblyPlaying: Bool,
        reduceMotion: Bool
    ) -> Bool {
        isPanelVisible && isAudiblyPlaying && !reduceMotion
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

    var body: some View {
        Group {
            if presentation.isVisible {
                MenuBarView(
                    onOpenSettings: onOpenSettings,
                    onOpenHistory: onOpenHistory
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Internal (not private) so DIBarApp+Debug.swift can drive the app.
    var appState: AppState!
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var panelTopLeft: NSPoint?
    private var lastLabelKey: String?
    private var speakerAnimationTimer: Timer?
    private let panelPresentation = PanelPresentationState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prefs migrates itself lazily on first access, so no ordering here.
        appState = AppState()

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
                }
            )
                .environment(appState)
                .environment(panelPresentation)
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

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncSpeakerAnimationClock() }
        }

        setupDebugNotifications()
    }

    // MARK: - Auxiliary windows

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func showSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsWindowView().environment(appState)
            ))
            window.title = "DIBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
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
        }
        presentAuxiliaryWindow(historyWindow!)
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
        let key = "\(line1 ?? "")|\(line2 ?? "")|\(glyph)"
        guard key != lastLabelKey else { return }
        lastLabelKey = key
        button.image = MenuBarLabelRenderer.labelImage(line1: line1, line2: line2, glyph: glyph)
    }
}

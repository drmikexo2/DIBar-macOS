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
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var panelTopLeft: NSPoint?
    private var lastLabelKey: String?

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

        let hosting = NSHostingController(
            rootView: MenuBarView()
                .environment(appState)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

        NotificationCenter.default.addObserver(forName: .dibarOpenSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showSettingsWindow() }
        }
        NotificationCenter.default.addObserver(forName: .dibarOpenHistory, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showHistoryWindow() }
        }

        setupDebugNotifications()
    }

    // MARK: - Auxiliary windows

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsWindowView().environment(appState)
            ))
            window.title = "DIBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showHistoryWindow() {
        if historyWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: HistoryWindowView().environment(appState)
            ))
            window.title = "Listening History"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 480))
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        historyWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.historyRecorder.appWillTerminate()
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
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
    }

    private func closePanel() {
        panelTopLeft = nil
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        appState.trackNotifier.popoverIsVisible = false
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

    private func setupDebugNotifications() {
        #if DEBUG
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.playFirst"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let appState = self?.appState, let channel = appState.channels.first else {
                    log.error("DEBUG: no channels loaded")
                    return
                }
                log.error("DEBUG: playing '\(channel.name, privacy: .public)'")
                appState.playChannel(channel)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.selectNetwork"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.object as? String
            Task { @MainActor in
                guard let raw, let network = Network(rawValue: raw) else {
                    log.error("DEBUG: unknown network '\(raw ?? "nil", privacy: .public)'")
                    return
                }
                log.error("DEBUG: selecting network \(network.rawValue, privacy: .public)")
                self?.appState.selectNetwork(network)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.togglePlayPause"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appState.togglePlayPause()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.stop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appState.audioPlayer.stop()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.openSettings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showSettingsWindow() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.openHistory"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showHistoryWindow() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.toggleArt"),
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("debugToggleArt"), object: nil)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.togglePanel"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.togglePanel(nil) }
        }

        log.error("DEBUG: notification handlers registered")
        #endif
    }
}

/// Composes the status item label (icon + optional play/pause glyph or
/// one/two text lines) into a single template image.
enum MenuBarLabelRenderer {
    enum PlaybackGlyph: String {
        case none, playing, paused, buffering, muted

        var symbolName: String? {
            switch self {
            case .none: return nil
            case .playing: return "play.fill"
            case .paused: return "pause.fill"
            case .buffering: return "arrow.triangle.2.circlepath"
            case .muted: return "speaker.slash.fill"
            }
        }
    }

    private static let height: CGFloat = 22
    private static let iconSide: CGFloat = 18
    private static let gap: CGFloat = 4
    private static let symbolGap: CGFloat = 8

    @MainActor
    static func glyph(for player: AudioPlayer) -> PlaybackGlyph {
        switch player.phase {
        case .buffering, .reconnecting: return .buffering
        default: break
        }
        if player.isPlaying, player.isMuted { return .muted }
        if player.isPlaying { return .playing }
        if player.currentChannel != nil { return .paused }
        return .none
    }

    static func labelImage(line1: String?, line2: String?, glyph: PlaybackGlyph) -> NSImage {
        // Layout: [symbol][symbolGap][icon][gap][text lines]
        var symbol: NSImage?
        if let symbolName = glyph.symbolName {
            symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: glyph.rawValue)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        }
        let symbolLeading = symbol.map { $0.size.width + symbolGap } ?? 0
        let iconX = symbolLeading

        // (text, drawing origin in points, unflipped coordinates)
        var texts: [(NSAttributedString, NSPoint)] = []
        let textX = iconX + iconSide + gap

        switch (line1, line2) {
        case (let l1?, let l2?):
            let t1 = NSAttributedString(string: l1, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.black,
            ])
            let t2 = NSAttributedString(string: l2, attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.black,
            ])
            texts = [(t1, NSPoint(x: textX, y: 11)), (t2, NSPoint(x: textX, y: 0.5))]
        case (let single?, nil), (nil, let single?):
            let t = NSAttributedString(string: single, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.black,
            ])
            texts = [(t, NSPoint(x: textX, y: (height - t.size().height) / 2))]
        case (nil, nil):
            break
        }

        let textBlockWidth = texts.map { $0.0.size().width + gap }.max() ?? 0
        let width = ceil(symbolLeading + iconSide + textBlockWidth + (texts.isEmpty ? 0 : 1))

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: width, height: height)) }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            let transform = NSAffineTransform()
            transform.scale(by: scale)
            transform.concat()

            // Transport glyph leads, icon follows: [symbol][gap][icon][text]
            if let symbol {
                let symbolSize = symbol.size
                symbol.draw(in: NSRect(
                    x: 0,
                    y: (height - symbolSize.height) / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                ))
            }
            if let icon = NSImage(named: "MenuBarIcon") {
                icon.draw(in: NSRect(x: iconX, y: (height - iconSide) / 2, width: iconSide, height: iconSide))
            }
            for (text, point) in texts {
                text.draw(at: point)
            }
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        rep.size = NSSize(width: width, height: height)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        // Template rendering keeps only the alpha channel, adapting to the
        // menu bar's light/dark appearance like any status item icon.
        image.isTemplate = true
        return image
    }
}

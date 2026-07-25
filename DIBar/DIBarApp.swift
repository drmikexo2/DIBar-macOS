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
    // Internal (not private) so DIBarApp+Debug.swift can drive the app.
    var appState: AppState!
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

    func showSettingsWindow() {
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

    func showHistoryWindow() {
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

    @objc func togglePanel(_ sender: Any?) {
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
}

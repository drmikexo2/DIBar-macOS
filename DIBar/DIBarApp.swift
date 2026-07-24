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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var appState: AppState!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var labelTimer: Timer?
    private var lastLabelKey: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(rootView: MenuBarView().environment(appState))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        refreshLabel()
        // The label only changes on track/state transitions; a 1s poll with a
        // change key keeps it current without observation plumbing.
        labelTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLabel() }
        }

        setupDebugNotifications()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Apply any label change deferred while the popover was open
        refreshLabel()
    }

    private func refreshLabel() {
        guard let button = statusItem.button else { return }
        // Never resize the status item while the popover is anchored to it —
        // a width change makes the popover jump around under the user.
        guard popover?.isShown != true else { return }
        let line1 = appState.menuBarLine1
        let line2 = appState.menuBarLine2
        let glyph = MenuBarLabelRenderer.glyph(for: appState.audioPlayer)
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
            forName: NSNotification.Name("com.dibar.debug.toggleArt"),
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("debugToggleArt"), object: nil)
        }

        log.error("DEBUG: notification handlers registered")
        #endif
    }
}

/// Composes the status item label (icon + optional play/pause glyph or
/// one/two text lines) into a single template image.
enum MenuBarLabelRenderer {
    enum PlaybackGlyph: String {
        case none, playing, paused

        var symbolName: String? {
            switch self {
            case .none: return nil
            case .playing: return "play.fill"
            case .paused: return "pause.fill"
            }
        }
    }

    private static let height: CGFloat = 22
    private static let iconSide: CGFloat = 18
    private static let gap: CGFloat = 4

    @MainActor
    static func glyph(for player: AudioPlayer) -> PlaybackGlyph {
        if player.isPlaying { return .playing }
        if player.currentChannel != nil { return .paused }
        return .none
    }

    static func labelImage(line1: String?, line2: String?, glyph: PlaybackGlyph) -> NSImage {
        // (text, drawing origin in points, unflipped coordinates)
        var texts: [(NSAttributedString, NSPoint)] = []
        let textX = iconSide + gap

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

        // Transport glyph shown only in icon-only mode
        var symbol: NSImage?
        if texts.isEmpty, let symbolName = glyph.symbolName {
            symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: glyph.rawValue)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        }

        let textWidth = texts.map { $0.0.size().width + ($0.1.x - iconSide) }.max() ?? -gap
        let symbolWidth = symbol.map { gap + $0.size.width } ?? 0
        let width = ceil(iconSide + max(textWidth, 0) + symbolWidth + (texts.isEmpty ? 0 : 1))

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

            if let icon = NSImage(named: "MenuBarIcon") {
                icon.draw(in: NSRect(x: 0, y: (height - iconSide) / 2, width: iconSide, height: iconSide))
            }
            for (text, point) in texts {
                text.draw(at: point)
            }
            if let symbol {
                let symbolSize = symbol.size
                symbol.draw(in: NSRect(
                    x: iconSide + gap,
                    y: (height - symbolSize.height) / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                ))
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

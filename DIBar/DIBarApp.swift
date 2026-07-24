import SwiftUI
import os

private let log = Logger(subsystem: "com.dibar", category: "App")

@main
struct DIBarApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .onAppear {
                    setupDebugNotifications()
                }
        } label: {
            HStack(spacing: 3) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                switch (appState.menuBarLine1, appState.menuBarLine2) {
                case (let line1?, let line2?):
                    // MenuBarExtra labels flatten stacked views, so two-line
                    // text is drawn into a template image instead.
                    Image(nsImage: MenuBarLabelRenderer.twoLineImage(line1: line1, line2: line2))
                case (let line?, nil), (nil, let line?):
                    Text(line)
                case (nil, nil):
                    if appState.audioPlayer.isPlaying {
                        Image(systemName: "play.fill")
                            .imageScale(.small)
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor private static var debugHandlersRegistered = false

    private func setupDebugNotifications() {
        #if DEBUG
        guard !Self.debugHandlersRegistered else { return }
        Self.debugHandlersRegistered = true
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.dibar.debug.playFirst"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard let channel = appState.channels.first else {
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
        ) { note in
            let raw = note.object as? String
            Task { @MainActor in
                guard let raw, let network = Network(rawValue: raw) else {
                    log.error("DEBUG: unknown network '\(raw ?? "nil", privacy: .public)'")
                    return
                }
                log.error("DEBUG: selecting network \(network.rawValue, privacy: .public)")
                appState.selectNetwork(network)
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

/// Draws two small text lines into a template image for the menu bar label,
/// since MenuBarExtra flattens multi-line SwiftUI views.
enum MenuBarLabelRenderer {
    static func twoLineImage(line1: String, line2: String) -> NSImage {
        let attrs1: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let attrs2: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.black,
        ]
        let text1 = NSAttributedString(string: line1, attributes: attrs1)
        let text2 = NSAttributedString(string: line2, attributes: attrs2)

        let lineHeight: CGFloat = 11
        let size = NSSize(
            width: ceil(max(text1.size().width, text2.size().width)),
            height: lineHeight * 2
        )
        let image = NSImage(size: size, flipped: true) { _ in
            text1.draw(at: NSPoint(x: 0, y: 0))
            text2.draw(at: NSPoint(x: 0, y: lineHeight))
            return true
        }
        // Template rendering keeps only the alpha channel, adapting the text
        // to light/dark menu bars like any status item icon.
        image.isTemplate = true
        return image
    }
}

import SwiftUI
import AppKit

/// Actions on a song's metadata: copy "Artist – Title" or search it in a
/// streaming service. Shared by the player popover and the History window.
enum SongAction: CaseIterable, Identifiable {
    case copy
    case spotify
    case appleMusic
    case youtube

    var id: Self { self }

    var title: String {
        switch self {
        case .copy: return "Copy Artist – Title"
        case .spotify: return "Search in Spotify"
        case .appleMusic: return "Search in Apple Music"
        case .youtube: return "Search in YouTube"
        }
    }

    var systemImage: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .spotify, .appleMusic, .youtube: return "magnifyingglass"
        }
    }

    func perform(artist: String, title: String) {
        let query = artist.isEmpty ? title : "\(artist) \(title)"
        switch self {
        case .copy:
            let line = TrackDisplay.artistTitle(artist, title)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
        case .spotify:
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            open("https://open.spotify.com/search/\(encoded)")
        case .appleMusic:
            open("https://music.apple.com/search", query: query, param: "term")
        case .youtube:
            open("https://www.youtube.com/results", query: query, param: "search_query")
        }
    }

    private func open(_ base: String, query: String? = nil, param: String? = nil) {
        guard var components = URLComponents(string: base) else { return }
        if let query, let param {
            components.queryItems = [URLQueryItem(name: param, value: query)]
        }
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Small ellipsis button opening a custom dropdown of SongActions, styled
/// after the NetworkPicker popover.
struct SongActionsButton: View {
    let artist: String
    let title: String
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help("Song actions")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SongActionsPopoverContent(artist: artist, title: title) {
                isOpen = false
            }
        }
    }
}

/// The dropdown body shared by the (…) button and the right-click menu.
private struct SongActionsPopoverContent: View {
    let artist: String
    let title: String
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SongAction.allCases) { action in
                SongActionRow(
                    label: action.title,
                    systemImage: action == .copy && copied ? "checkmark" : action.systemImage
                ) {
                    action.perform(artist: artist, title: title)
                    if action == .copy {
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            copied = false
                            dismiss()
                        }
                    } else {
                        dismiss()
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 190)
    }
}

// MARK: - Right-click presentation

extension View {
    /// Present the styled SongActions dropdown on right-click (or
    /// control-click), replacing a native `.contextMenu` so the menu looks
    /// the same everywhere the (…) button's popover does.
    func songActionsMenu(artist: String, title: String) -> some View {
        modifier(SongActionsRightClickModifier(artist: artist, title: title))
    }
}

private struct SongActionsRightClickModifier: ViewModifier {
    let artist: String
    let title: String
    @State private var isOpen = false
    @State private var clickPoint = CGPoint.zero

    func body(content: Content) -> some View {
        content
            .overlay {
                RightClickCatcher { point in
                    clickPoint = point
                    isOpen = true
                }
            }
            .popover(
                isPresented: $isOpen,
                attachmentAnchor: .rect(.rect(CGRect(origin: clickPoint, size: CGSize(width: 1, height: 1)))),
                arrowEdge: .bottom
            ) {
                SongActionsPopoverContent(artist: artist, title: title) {
                    isOpen = false
                }
            }
    }
}

/// Transparent overlay that intercepts only secondary clicks — hitTest turns
/// every other event away so buttons underneath keep working.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Void)?

        // Match SwiftUI's top-left coordinate space so the reported point
        // can anchor the popover directly.
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                onRightClick?(convert(event.locationInWindow, from: nil))
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

private struct SongActionRow: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        DropdownRow(spacing: 6, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 12))
            Spacer()
        }
    }
}

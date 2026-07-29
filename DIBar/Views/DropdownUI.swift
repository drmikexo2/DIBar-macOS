import SwiftUI

/// Shared chrome for the custom dropdown popovers (NetworkPicker,
/// OutputDevicePicker, SleepTimerView, SongActionsMenu). Native Menu can't
/// right-justify icons or color individual rows, so these popovers are hand
/// built — this file keeps them pixel-identical to each other.

/// The popover shell: left-aligned zero-spacing column, 4pt vertical inset,
/// fixed width.
struct DropdownContainer<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.vertical, 4)
        .frame(width: width)
    }
}

/// One tappable row: plain button, hover highlight, standard 12/5 padding.
struct DropdownRow<Content: View>: View {
    var spacing: CGFloat? = 4
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: spacing) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

/// Fixed-width leading checkmark slot so labels align whether selected or not.
struct DropdownCheckmark: View {
    let isVisible: Bool

    var body: some View {
        Group {
            if isVisible {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Color.clear
            }
        }
        .frame(width: 16, height: 14)
    }
}

/// Playing-station text treatment: the system accent as-is in light mode, but
/// slightly lightened in dark mode — Night Shift filters out blue light, so
/// pure accent blue on a dark background turns unreadably muddy. Built from
/// live Color.accentColor plus a brightness filter (not a pre-blended
/// NSColor) so the text follows accent-color changes instantly.
private struct PlayingHighlight: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isPlaying: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
            .brightness(isPlaying && colorScheme == .dark ? 0.1 : 0)
    }
}

extension View {
    /// Colors a station-name label for its playing state (accent when
    /// playing, primary otherwise), dark-mode-brightness-corrected.
    func playingHighlight(_ isPlaying: Bool) -> some View {
        modifier(PlayingHighlight(isPlaying: isPlaying))
    }
}

/// Pure presentation mapping for SpeakerIndicator, kept separate so the
/// stepped animation can be tested without instantiating SwiftUI views.
enum SpeakerIndicatorPresentation {
    static let steadyWaveSymbol = "speaker.wave.2.fill"
    static let waveSymbols = [
        "speaker.wave.1.fill",
        steadyWaveSymbol,
        "speaker.wave.3.fill",
    ]
    static var waveFrameCount: Int { waveSymbols.count }
    static let waveCycleDuration: TimeInterval = 2.0
    static var waveFrameInterval: TimeInterval {
        waveCycleDuration / Double(waveFrameCount)
    }

    static func symbolName(
        isCurrent: Bool,
        isAudible: Bool,
        waveFrame: Int,
        reduceMotion: Bool = false
    ) -> String? {
        guard isCurrent else { return nil }
        guard isAudible else { return "speaker.fill" }
        return waveSymbol(waveFrame: waveFrame, reduceMotion: reduceMotion)
    }

    static func waveSymbol(waveFrame: Int, reduceMotion: Bool) -> String {
        guard !reduceMotion else { return steadyWaveSymbol }
        return waveSymbols[waveIndex(waveFrame: waveFrame, reduceMotion: false)]
    }

    static func waveIndex(waveFrame: Int, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return 1 }
        return ((waveFrame % waveSymbols.count) + waveSymbols.count) % waveSymbols.count
    }
}

/// Fixed-width trailing speaker slot: low-rate stepped blue waves while
/// audible, a muted speaker while current-but-paused, empty otherwise.
/// All instances share the panel's isolated clock; there is deliberately no
/// symbolEffect, interpolated transition, or changing Image identity here.
struct SpeakerIndicator: View {
    @Environment(PanelPresentationState.self) private var panelPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isCurrent: Bool
    let isAudible: Bool

    var body: some View {
        Group {
            if isCurrent && isAudible {
                ZStack(alignment: .leading) {
                    waveLayer(symbol: "speaker.wave.1.fill", index: 0)
                    waveLayer(symbol: "speaker.wave.2.fill", index: 1)
                    waveLayer(symbol: "speaker.wave.3.fill", index: 2)
                }
            } else if isCurrent {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
            }
        }
        // The SF Symbol variants have different intrinsic widths (roughly
        // 12/14/17pt at this size). A leading-aligned frame keeps the speaker
        // body and each successive wave at fixed x coordinates instead of
        // recentering the whole glyph on every step.
        .frame(width: 18, height: 14, alignment: .leading)
    }

    private func waveLayer(symbol: String, index: Int) -> some View {
        Image(systemName: symbol)
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .opacity(activeWaveIndex == index ? 1 : 0)
    }

    private var activeWaveIndex: Int {
        SpeakerIndicatorPresentation.waveIndex(
            waveFrame: panelPresentation.speakerWaveFrame,
            reduceMotion: reduceMotion
        )
    }
}

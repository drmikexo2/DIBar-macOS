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

/// Fixed-width trailing speaker slot: blue waves while audible, a muted
/// speaker while current-but-paused, empty otherwise.
struct SpeakerIndicator: View {
    let isCurrent: Bool
    let isAudible: Bool

    var body: some View {
        Group {
            if isCurrent && isAudible {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            } else if isCurrent {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
            }
        }
        .frame(width: 16, height: 14)
    }
}

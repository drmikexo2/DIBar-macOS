import AppKit

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

    static func labelImage(
        line1: String?,
        line2: String?,
        glyph: PlaybackGlyph,
        showsUpdateBadge: Bool = false
    ) -> NSImage {
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
            if showsUpdateBadge {
                let badgeRect = NSRect(
                    x: iconX + iconSide - 5,
                    y: (height + iconSide) / 2 - 5,
                    width: 5,
                    height: 5
                )
                // Punch out a one-point halo so the template badge remains
                // legible even when it overlaps an opaque part of the icon.
                context.compositingOperation = .clear
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
                context.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
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

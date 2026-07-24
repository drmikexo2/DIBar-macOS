import Foundation

/// Shared normalization and matching for song metadata across sources. The
/// API and the ICY stream title render the same track differently: quote
/// characters and spacing vary, and ICY often carries a remix suffix the
/// API's canonical name lacks ("Get It On (Saison Remix)" vs "Get It On").
enum TrackMatching {
    /// Canonical form for comparing song metadata across sources: ICY and the
    /// API render the same title with different quote characters and spacing.
    static func mergeKey(_ text: String) -> String {
        // backtick, acute, left/right single curly quotes, reversed quote,
        // modifier apostrophe, prime — all fold to a straight apostrophe
        let quoteVariants = "`´\u{2018}\u{2019}\u{201B}\u{02BC}\u{2032}"
        let folded = text.lowercased().map { char -> Character in
            quoteVariants.contains(char) ? "'" : char
        }
        return String(folded)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Whether two metadata pairs plausibly name the same track: artists must
    /// match (two empty artists fall back to the titles alone — ICY can't
    /// always split one out), and titles match exactly or one extends the
    /// other at a word boundary ("Get It On" ⊂ "Get It On (Saison Remix)",
    /// but not "Get It Online").
    static func sameSong(artistA: String, titleA: String, artistB: String, titleB: String) -> Bool {
        let a = mergeKey(titleA)
        let b = mergeKey(titleB)
        guard !a.isEmpty, !b.isEmpty else { return false }
        guard mergeKey(artistA) == mergeKey(artistB) else { return false }
        return a == b || extendsAtWordBoundary(a, beyond: b) || extendsAtWordBoundary(b, beyond: a)
    }

    private static func extendsAtWordBoundary(_ longer: String, beyond shorter: String) -> Bool {
        guard longer.count > shorter.count, longer.hasPrefix(shorter) else { return false }
        let next = longer[longer.index(longer.startIndex, offsetBy: shorter.count)]
        return next == " " || next == "("
    }
}

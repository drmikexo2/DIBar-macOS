import Foundation

enum Network: String, CaseIterable, Identifiable, Codable {
    // Declaration order is display order (picker, login grid, site-cycle
    // hotkeys): alphabetical by displayName.
    case classicalradio
    case di
    case jazzradio
    case radiotunes
    case rockradio
    case zenradio

    var id: String { rawValue }

    var apiSlug: String { rawValue }

    var listenDomain: String {
        switch self {
        case .classicalradio: return "classicalradio.com"
        case .di:             return "di.fm"
        case .jazzradio:      return "jazzradio.com"
        case .radiotunes:     return "radiotunes.com"
        case .rockradio:      return "rockradio.com"
        case .zenradio:       return "zenradio.com"
        }
    }

    var shortLabel: String {
        switch self {
        case .classicalradio: return "Classical"
        case .di:             return "DI.FM"
        case .jazzradio:      return "Jazz"
        case .radiotunes:     return "Tunes"
        case .rockradio:      return "Rock"
        case .zenradio:       return "Zen"
        }
    }

    var displayName: String {
        switch self {
        case .classicalradio: return "Classical Radio"
        case .di:             return "DI.FM"
        case .jazzradio:      return "Jazz Radio"
        case .radiotunes:     return "Radio Tunes"
        case .rockradio:      return "Rock Radio"
        case .zenradio:       return "Zen Radio"
        }
    }

    /// AudioAddict network_id as it appears in membership subscriptions.
    /// Best-known community values; loadMembership logs the real ones so a
    /// mismatch shows up in Console rather than as silent wrong gating.
    var networkId: Int {
        switch self {
        case .di:             return 1
        case .radiotunes:     return 2
        case .jazzradio:      return 3
        case .rockradio:      return 4
        case .classicalradio: return 5
        case .zenradio:       return 6
        }
    }

    static func from(networkId: Int) -> Network? {
        allCases.first { $0.networkId == networkId }
    }

    var apiBaseURL: String {
        "https://api.audioaddict.com/v1/\(apiSlug)"
    }

    var listenBaseURL: String {
        "https://listen.\(listenDomain)"
    }
}

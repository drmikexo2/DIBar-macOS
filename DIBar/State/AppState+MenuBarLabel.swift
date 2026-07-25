import Foundation

/// Menu-bar label composition: which components show is governed by the
/// toggles stored on AppState; this file owns how they join and truncate.
extension AppState {
    /// "Site · Station" for the menu bar, per the component toggles; nil when
    /// idle or nothing is selected for this line.
    var menuBarLine1: String? {
        guard audioPlayer.isPlaying else { return nil }
        return composedLine1(
            site: audioPlayer.currentNetwork?.displayName,
            station: audioPlayer.currentChannel?.name
        )
    }

    /// "Artist – Song" for the menu bar, per the component toggles.
    var menuBarLine2: String? {
        guard audioPlayer.isPlaying, let track = audioPlayer.currentTrack else { return nil }
        return composedLine2(artist: track.artist, song: track.title)
    }

    /// Preview variants for the settings area: live values while playing,
    /// placeholder examples otherwise. Same joining logic as the real label.
    var menuBarPreviewLine1: String? {
        composedLine1(
            site: audioPlayer.isPlaying ? audioPlayer.currentNetwork?.displayName : "Jazz Radio",
            station: audioPlayer.isPlaying ? audioPlayer.currentChannel?.name : "Ambient"
        )
    }

    var menuBarPreviewLine2: String? {
        if audioPlayer.isPlaying, let track = audioPlayer.currentTrack {
            return composedLine2(artist: track.artist, song: track.title)
        }
        return composedLine2(artist: "Metallica", song: "So What")
    }

    private func composedLine1(site: String?, station: String?) -> String? {
        var parts: [String] = []
        if menuBarShowSite, let site, !site.isEmpty {
            parts.append(site)
        }
        if menuBarShowStation, let station, !station.isEmpty {
            parts.append(station)
        }
        guard !parts.isEmpty else { return nil }
        return Self.truncateForMenuBar(parts.joined(separator: " · "))
    }

    private func composedLine2(artist: String?, song: String?) -> String? {
        var parts: [String] = []
        if menuBarShowArtist, let artist, !artist.isEmpty {
            parts.append(artist)
        }
        if menuBarShowSong, let song, !song.isEmpty, song != "Loading..." {
            parts.append(song)
        }
        guard !parts.isEmpty else { return nil }
        return Self.truncateForMenuBar(parts.joined(separator: " – "))
    }

    private static func truncateForMenuBar(_ text: String) -> String {
        text.count > 35 ? String(text.prefix(34)) + "…" : text
    }
}

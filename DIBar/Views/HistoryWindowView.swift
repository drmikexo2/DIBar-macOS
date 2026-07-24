import SwiftUI

/// Content of the "Listening History" window: Listened / Liked / Disliked.
struct HistoryWindowView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case listened = "Listened"
        case liked = "Liked"
        case disliked = "Disliked"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    @State private var tab: Tab = .listened
    @State private var listens: [HistoryStore.ListenEntry] = []
    @State private var votes: [HistoryStore.VoteEntry] = []
    @State private var allTimeSeconds: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                Spacer()

                if tab == .listened {
                    Text("Today \(Self.formatTime(appState.historyRecorder.todayListenedSeconds)) · All time \(Self.formatTime(allTimeSeconds))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .listened:
                        if listens.isEmpty {
                            emptyState
                        }
                        ForEach(listens) { entry in
                            listenRow(entry)
                        }
                    case .liked, .disliked:
                        if votes.isEmpty {
                            emptyState
                        }
                        ForEach(votes) { entry in
                            voteRow(entry)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 460, idealWidth: 460, minHeight: 300, idealHeight: 480)
        .onAppear { reload() }
        .onChange(of: tab) { _, _ in reload() }
    }

    private func reload() {
        switch tab {
        case .listened:
            listens = appState.historyRecorder.recentListens()
            allTimeSeconds = appState.historyRecorder.allTimeListenedSeconds()
        case .liked:
            votes = appState.historyRecorder.voteEntries(vote: 1)
        case .disliked:
            votes = appState.historyRecorder.voteEntries(vote: -1)
        }
    }

    // MARK: - Rows

    private func listenRow(_ entry: HistoryStore.ListenEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Liked/disliked songs stand out in the listened list
            Group {
                if let vote = entry.vote {
                    Image(systemName: vote > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(vote > 0 ? AnyShapeStyle(.green.opacity(0.8)) : AnyShapeStyle(.red.opacity(0.6)))
                } else {
                    Color.clear
                }
            }
            .frame(width: 14, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(songLine(artist: entry.artist, title: entry.title))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text("\(entry.channelName) · \(siteName(entry.network))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.dateFormatter.string(from: entry.startedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(Self.formatDuration(entry.duration))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func voteRow(_ entry: HistoryStore.VoteEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.vote > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                .font(.system(size: 10))
                .foregroundStyle(entry.vote > 0 ? AnyShapeStyle(.green.opacity(0.8)) : AnyShapeStyle(.red.opacity(0.6)))
            VStack(alignment: .leading, spacing: 1) {
                Text(songLine(artist: entry.artist, title: entry.title))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text("\(entry.channelName) · \(siteName(entry.network))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(Self.dateFormatter.string(from: entry.votedAt))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private var emptyState: some View {
        Text("Nothing here yet")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    // MARK: - Formatting

    private func songLine(artist: String, title: String) -> String {
        if artist.isEmpty { return title }
        if title.isEmpty { return artist }
        return "\(artist) – \(title)"
    }

    private func siteName(_ raw: String) -> String {
        Network(rawValue: raw)?.displayName ?? raw
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

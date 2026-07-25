import SwiftUI

/// Moon button with a custom dropdown for the sleep timer, styled after the
/// NetworkPicker popover. The 1s countdown timer exists only while a sleep
/// timer is active — idle, this view never re-renders.
struct SleepTimerView: View {
    @Environment(AppState.self) private var appState
    @State private var isOpen = false
    @State private var customMinutes = Prefs.string(.sleepTimerCustomMinutes) ?? "45"

    private let presets = [15, 30, 60, 90]

    private var isActive: Bool { appState.sleepTimerEndDate != nil }

    var body: some View {
        HStack(spacing: 4) {
            if let endDate = appState.sleepTimerEndDate {
                CountdownText(endDate: endDate) { remaining in
                    Text(NowPlaying.formatTime(remaining))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Button {
                isOpen.toggle()
            } label: {
                Image(systemName: isActive ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("Sleep timer")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                popoverContent
            }
        }
    }

    private var popoverContent: some View {
        DropdownContainer(width: 170) {
            if let endDate = appState.sleepTimerEndDate {
                HStack {
                    CountdownText(endDate: endDate) { remaining in
                        Text("Stops in \(NowPlaying.formatTime(remaining))")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)

                TimerRow(label: "Cancel timer", tint: .red) {
                    appState.cancelSleepTimer()
                    isOpen = false
                }

                Divider()
                    .padding(.vertical, 4)
            }

            ForEach(presets, id: \.self) { minutes in
                TimerRow(label: "\(minutes) minutes") {
                    appState.startSleepTimer(minutes: minutes)
                    isOpen = false
                }
            }

            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 6) {
                TextField("min", text: $customMinutes)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 44)
                    .onSubmit(startCustomTimer)
                Text("minutes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start", action: startCustomTimer)
                    .controlSize(.small)
                    .disabled(Int(customMinutes) == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }

    private func startCustomTimer() {
        guard let minutes = Int(customMinutes), minutes > 0 else { return }
        Prefs.set(String(minutes), for: .sleepTimerCustomMinutes)
        appState.startSleepTimer(minutes: minutes)
        isOpen = false
    }
}

/// Owns the once-per-second tick so only the label re-renders, and only
/// while a countdown is showing.
private struct CountdownText<Content: View>: View {
    let endDate: Date
    @ViewBuilder let content: (Int) -> Content
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        content(max(Int(endDate.timeIntervalSince(now)), 0))
            .onReceive(timer) { now = $0 }
    }
}

private struct TimerRow: View {
    let label: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        DropdownRow(action: action) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Spacer()
        }
    }
}

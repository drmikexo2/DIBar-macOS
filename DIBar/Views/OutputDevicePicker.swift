import SwiftUI
import AVKit

/// Speaker button opening a custom dropdown of output devices, styled after
/// the NetworkPicker popover. The one system-drawn control is the AirPlay
/// row's AVRoutePickerView — there is no public API to enumerate AirPlay
/// targets, so that single affordance has to be Apple's.
struct OutputDevicePicker: View {
    @Environment(AppState.self) private var appState
    @State private var isOpen = false

    private var isRouted: Bool { appState.outputDeviceUID != nil }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "hifispeaker")
                .font(.system(size: 11))
                .foregroundStyle(isRouted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help("Output device")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DropdownContainer(width: 230) {
                DeviceRow(label: "System Default", isSelected: appState.outputDeviceUID == nil) {
                    appState.setOutputDevice(uid: nil)
                    isOpen = false
                }
                ForEach(appState.deviceManager.devices) { device in
                    DeviceRow(label: device.name, isSelected: appState.outputDeviceUID == device.uid) {
                        appState.setOutputDevice(uid: device.uid)
                        isOpen = false
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                HStack(spacing: 4) {
                    AirPlayButton(player: appState.audioPlayer.routePickerPlayer)
                        .frame(width: 22, height: 18)
                    Text("AirPlay…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }
        }
    }
}

private struct DeviceRow: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        DropdownRow(action: action) {
            DropdownCheckmark(isVisible: isSelected)
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
        }
    }
}

private struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player
    }
}

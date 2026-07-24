import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.dibar", category: "AudioDeviceManager")

/// Enumerates output-capable CoreAudio devices and watches for hot-plug
/// changes. Routing itself happens in AudioPlayer via
/// AVPlayer.audioOutputDeviceUniqueID; this only supplies the device list.
@Observable
@MainActor
final class AudioDeviceManager {
    struct OutputDevice: Identifiable, Equatable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    private(set) var devices: [OutputDevice] = []
    var onDevicesChanged: (() -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        installListener()
    }

    func refresh() {
        var address = Self.systemAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            devices = []
            return
        }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return }
        devices = ids.compactMap { outputDevice(id: $0) }
    }

    private func installListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.onDevicesChanged?()
            }
        }
        listenerBlock = block
        var address = Self.systemAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        var defaultAddress = Self.systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main, block
        )
    }

    // MARK: - Property plumbing

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func outputDevice(id: AudioObjectID) -> OutputDevice? {
        guard outputChannelCount(id: id) > 0,
              let uid = stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id: id, selector: kAudioObjectPropertyName)
        else { return nil }
        return OutputDevice(uid: uid, name: name)
    }

    private func outputChannelCount(id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func stringProperty(id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = Self.systemAddress(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

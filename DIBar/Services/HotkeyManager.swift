import AppKit
import Carbon
import os

private let log = Logger(subsystem: "com.dibar", category: "HotkeyManager")

/// System-wide hotkeys via Carbon RegisterEventHotKey — the one global-key
/// API that works inside the sandbox without an Accessibility prompt
/// (CGEventTap and NSEvent global monitors both need it).
@MainActor
final class HotkeyManager {
    enum Action: UInt32 {
        case playPause = 1
        case nextFavorite = 2
        case previousFavorite = 3
        case nextSite = 4
        case previousSite = 5
    }

    var onAction: ((Action) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4449_4252 // "DIBR"

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let action = Action(rawValue: hotKeyID.id)
                Task { @MainActor in
                    if let action { manager.onAction?(action) }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            log.error("InstallEventHandler failed: \(installStatus)")
            eventHandlerRef = nil
            return
        }

        // ⌃⌥⌘ three-modifier combos minimize collisions with other apps
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        registerKey(.playPause, keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers)
        registerKey(.nextFavorite, keyCode: UInt32(kVK_RightArrow), modifiers: modifiers)
        registerKey(.previousFavorite, keyCode: UInt32(kVK_LeftArrow), modifiers: modifiers)
        registerKey(.nextSite, keyCode: UInt32(kVK_UpArrow), modifiers: modifiers)
        registerKey(.previousSite, keyCode: UInt32(kVK_DownArrow), modifiers: modifiers)
    }

    private func registerKey(_ action: Action, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        } else {
            // Another app owns the combo — non-fatal, the other key may still work
            log.error("RegisterEventHotKey(\(action.rawValue)) failed: \(status)")
        }
    }

    private func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs = []
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}

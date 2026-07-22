import Carbon
import Foundation

@MainActor
protocol GlobalShortcutManaging: AnyObject {
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws
    func unregister()
}

/// User-facing shortcut choices kept intentionally small so every saved value
/// can be registered deterministically with Carbon.
enum AssistantShortcutPreset: String, CaseIterable, Identifiable, Sendable {
    case optionSpace = "option_space"
    case controlOptionSpace = "control_option_space"
    case commandOptionSpace = "command_option_space"

    static let `default`: Self = .optionSpace

    var id: Self { self }

    var displayName: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .commandOptionSpace: "⌘⌥Space"
        }
    }

    var keyCode: UInt32 { UInt32(kVK_Space) }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .commandOptionSpace: UInt32(cmdKey | optionKey)
        }
    }
}

enum GlobalShortcutError: Error, Equatable, LocalizedError {
    case eventHandlerRegistrationFailed(OSStatus)
    case hotKeyRegistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandlerRegistrationFailed:
            "The global shortcut event handler could not be installed."
        case .hotKeyRegistrationFailed:
            "The global shortcut could not be registered."
        }
    }
}

/// Registers one configurable Carbon hot key for the meeting assistant.
/// Reconfiguration always unregisters the previous shortcut first.
@MainActor
final class GlobalShortcutManager {
    nonisolated static let defaultKeyCode = AssistantShortcutPreset.default.keyCode
    nonisolated static let defaultModifiers = AssistantShortcutPreset.default.modifiers

    nonisolated private static let signature: OSType = 0x4343_4153 // "CCAS"
    nonisolated private static let identifier: UInt32 = 1

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var handler: (@MainActor @Sendable () -> Void)?

    func register(
        keyCode: UInt32 = GlobalShortcutManager.defaultKeyCode,
        modifiers: UInt32 = GlobalShortcutManager.defaultModifiers,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalShortcutManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
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

                let signature = hotKeyID.signature
                let identifier = hotKeyID.id
                Task { @MainActor in
                    manager.invoke(signature: signature, identifier: identifier)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            eventHandlerRef = nil
            throw GlobalShortcutError.eventHandlerRegistrationFailed(handlerStatus)
        }

        self.handler = handler
        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            self.handler = nil
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            eventHandlerRef = nil
            hotKeyRef = nil
            throw GlobalShortcutError.hotKeyRegistrationFailed(registrationStatus)
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        handler = nil

        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        eventHandlerRef = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    private func invoke(signature: OSType, identifier: UInt32) {
        guard signature == Self.signature, identifier == Self.identifier else { return }
        handler?()
    }
}

extension GlobalShortcutManager: GlobalShortcutManaging {}

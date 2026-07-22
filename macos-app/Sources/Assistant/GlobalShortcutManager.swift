import Carbon
import Foundation

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
    nonisolated static let defaultKeyCode = UInt32(kVK_Space)
    nonisolated static let defaultModifiers = UInt32(optionKey)

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

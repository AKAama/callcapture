import Carbon
import Foundation
import Testing
@testable import CallCapture

@Suite("Realtime app integration")
struct RealtimeIntegrationTests {
    @Test("app runtime registers, replaces, unregisters, and clears realtime owners")
    @MainActor func appRuntimeLifecycle() throws {
        let path = NSTemporaryDirectory() + "cc-realtime-runtime-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let shortcut = RecordingGlobalShortcutManager()
        let appModel = AppModel(
            database: try AppDatabase(path: path),
            globalShortcutManager: shortcut
        )

        appModel.startRuntime()
        #expect(shortcut.registrations == [
            .init(
                keyCode: AssistantShortcutPreset.optionSpace.keyCode,
                modifiers: AssistantShortcutPreset.optionSpace.modifiers
            ),
        ])

        appModel.settingsManager.assistantShortcutPreset = .controlOptionSpace
        appModel.reconfigureAssistantShortcut()
        #expect(shortcut.registrations.last == .init(
            keyCode: AssistantShortcutPreset.controlOptionSpace.keyCode,
            modifiers: AssistantShortcutPreset.controlOptionSpace.modifiers
        ))

        appModel.settingsManager.assistantShortcutEnabled = false
        appModel.reconfigureAssistantShortcut()
        #expect(shortcut.unregisterCount == 3)

        appModel.liveTranscriptStore.apply(.confirmed(
            id: "private-transcript",
            speakerID: "1",
            text: "private transcript marker",
            startMS: 0,
            endMS: 1_000
        ))
        #expect(appModel.meetingAssistant.compose(instruction: "organize"))
        appModel.meetingAssistant.draft = "private assistant marker"

        appModel.teardownForExit()

        #expect(shortcut.unregisterCount == 4)
        #expect(appModel.liveTranscriptStore.confirmedUtterances.isEmpty)
        #expect(appModel.liveTranscriptStore.partialUtterance == nil)
        #expect(appModel.meetingAssistant.state == .idle)
        #expect(appModel.meetingAssistant.contextText.isEmpty)
        #expect(appModel.meetingAssistant.draft.isEmpty)
        #expect(appModel.meetingAssistant.reply.isEmpty)
    }

    @Test("live coordinator states drive the primary menu action")
    func statePresentation() {
        #expect(RealtimeMeetingPresentation(state: .idle).primaryAction == .start)
        #expect(RealtimeMeetingPresentation(state: .connecting).primaryAction == .stop)
        #expect(RealtimeMeetingPresentation(state: .live).primaryAction == .stop)
        #expect(RealtimeMeetingPresentation(state: .reconnecting).primaryAction == .stop)
        #expect(RealtimeMeetingPresentation(state: .review).primaryAction == .startNewMeeting)
        #expect(RealtimeMeetingPresentation(state: .error).primaryAction == .start)

        #expect(RealtimeMeetingPresentation(state: .live).statusText == "实时字幕")
        #expect(RealtimeMeetingPresentation(state: .reconnecting).statusText == "正在重连…")
        #expect(RealtimeMeetingPresentation(state: .review).statusText == "字幕可查看")
    }

    @Test("preflight privacy notice matches the approved copy exactly")
    func privacyNotice() {
        #expect(
            RealtimePrivacy.notice ==
                "所选应用音频会发送到腾讯云 ASR；只有手动提交时，最近 30 秒字幕才会发送到所配置的 LLM；内容不会保存到本地"
        )
    }

    @Test("assistant shortcut defaults to Option-Space and offers safe replacements")
    func shortcutPresets() {
        #expect(AssistantShortcutPreset.default == .optionSpace)
        #expect(AssistantShortcutPreset.optionSpace.keyCode == UInt32(kVK_Space))
        #expect(AssistantShortcutPreset.optionSpace.modifiers == UInt32(optionKey))
        #expect(Set(AssistantShortcutPreset.allCases.map(\.modifiers)).count == AssistantShortcutPreset.allCases.count)
    }

    @Test("realtime credentials stay in Keychain and shortcut preferences reload")
    func realtimeSettings() throws {
        let path = NSTemporaryDirectory() + "cc-realtime-settings-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try AppDatabase(path: path)
        let saves = RealtimeSettingsSaveRecorder()
        let loadedSecrets = [
            SettingsManager.tencentASRAppIDAccount: "loaded-app-id",
            SettingsManager.tencentASRSecretIDAccount: "loaded-secret-id",
            SettingsManager.tencentASRSecretKeyAccount: "loaded-secret-key",
        ]

        let settings = SettingsManager(
            database: database,
            loadSecret: { loadedSecrets[$0] ?? "" },
            saveSecret: { value, account in
                saves.record(value: value, account: account)
            }
        )

        #expect(settings.tencentASRAppID == "loaded-app-id")
        #expect(settings.tencentASRSecretID == "loaded-secret-id")
        #expect(settings.tencentASRSecretKey == "loaded-secret-key")
        #expect(saves.values.isEmpty)
        #expect(settings.assistantShortcutEnabled)
        #expect(settings.assistantShortcutPreset == .optionSpace)

        settings.tencentASRSecretKey = "replacement-key"
        settings.assistantShortcutEnabled = false
        settings.assistantShortcutPreset = .controlOptionSpace

        #expect(saves.values[SettingsManager.tencentASRSecretKeyAccount] == "replacement-key")

        let reloaded = SettingsManager(
            database: database,
            loadSecret: { loadedSecrets[$0] ?? "" },
            saveSecret: { _, _ in }
        )
        #expect(!reloaded.assistantShortcutEnabled)
        #expect(reloaded.assistantShortcutPreset == .controlOptionSpace)
    }
}

private struct ShortcutRegistration: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
}

@MainActor
private final class RecordingGlobalShortcutManager: GlobalShortcutManaging {
    private(set) var registrations: [ShortcutRegistration] = []
    private(set) var unregisterCount = 0
    private var handler: (@MainActor @Sendable () -> Void)?

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws {
        registrations.append(.init(keyCode: keyCode, modifiers: modifiers))
        self.handler = handler
    }

    func unregister() {
        unregisterCount += 1
        handler = nil
    }
}

private final class RealtimeSettingsSaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    var values: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(value: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        stored[account] = value
    }
}

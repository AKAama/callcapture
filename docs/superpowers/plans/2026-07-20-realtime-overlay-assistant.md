# 实时会议悬浮助手实施计划

> **面向智能代理执行者：** 必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，按任务逐项实施。所有步骤使用复选框跟踪。

**目标：** 将 CallCapture 改造成仅捕获指定会议应用声音、实时显示中英文话者字幕，并能用最近 30 秒字幕手动调用可配置 LLM 的 macOS 悬浮助手。

**架构：** 保留 Swift/Core Audio 采集基础，将磁盘写入改为向有界内存队列输出 PCM；腾讯云 WebSocket 负责实时 ASR 和话者分离；`LiveTranscriptStore` 作为唯一内存数据源，分别驱动 `NSPanel` 字幕窗口和 LLM 助手。ASR、字幕和 LLM 使用独立任务，LLM 故障不能改变采集状态。

**技术栈：** macOS 14.2+、Swift 5.9、SwiftUI、AppKit、Core Audio Process Tap、AVFoundation、URLSession WebSocket、Security/Keychain、Swift Testing。

## 全局约束

- 只支持 macOS 14.2 及以上版本。
- 只捕获用户明确选择的会议应用，不打开麦克风。
- 音频转换为 16 kHz、单声道、16-bit signed PCM，且不写入磁盘。
- 字幕、Prompt 和模型回复只保存在内存；关闭窗口、开始新会议或退出应用时全部清除。
- 第一版 ASR 使用腾讯云实时中英文话者分离接口。
- 第一版 LLM 只支持 OpenAI-compatible 流式 Chat Completions。
- LLM 默认只使用最近 30 秒已确认字幕；不得包含临时字幕。
- API Key 只保存到 macOS Keychain；日志不得包含音频、字幕、Prompt、回复、密钥或签名 URL。
- Core Audio 实时回调不得执行网络、文件 IO、锁等待或 UI 更新。

---

## 文件结构

新增文件按责任划分：

- `Sources/Live/TranscriptModels.swift`：统一字幕事件、话语和连接状态。
- `Sources/Live/LiveTranscriptStore.swift`：仅内存字幕状态、去重、30 秒上下文和清空。
- `Sources/Live/PCMChunkBuffer.swift`：线程安全有界 PCM 队列。
- `Sources/Live/LiveTranscriber.swift`：ASR Provider 协议和配置。
- `Sources/Live/TencentTranscriptDecoder.swift`：腾讯云 JSON 到统一事件的纯解析。
- `Sources/Live/TencentSigner.swift`：腾讯云 WebSocket 请求签名。
- `Sources/Live/TencentLiveTranscriber.swift`：WebSocket 连接、发送、重连和事件流。
- `Sources/Live/LiveMeetingCoordinator.swift`：采集、ASR、字幕生命周期编排。
- `Sources/Capture/AudioProcessEnumerator.swift`：列出可选择的音频进程。
- `Sources/UI/SubtitlePanelController.swift`：管理原生 `NSPanel`。
- `Sources/UI/LiveSubtitleView.swift`：实时字幕和停止后的全文查看。
- `Sources/Assistant/LLMConfiguration.swift`：Provider 预设和配置校验。
- `Sources/Assistant/OpenAICompatibleClient.swift`：流式 Chat Completions 客户端。
- `Sources/Assistant/MeetingAssistant.swift`：30 秒上下文、Prompt 和请求生命周期。
- `Sources/UI/AssistantPanelController.swift`、`AssistantView.swift`：助手输入与回复窗口。
- `Sources/Assistant/GlobalShortcutManager.swift`：注册和释放可配置全局快捷键。

修改现有文件：

- `Sources/Capture/AudioCaptureManager.swift`：支持指定进程和 PCM sink，不创建音频文件。
- `Sources/App/CallCaptureApp.swift`：接入新 coordinator、状态和窗口控制。
- `Sources/App/ContentView.swift`：把设备/录音 UI 改为会议应用选择与实时字幕控制。
- `Sources/App/AppDelegate.swift`：退出时清除内存并关闭流。
- `Sources/Settings/SettingsManager.swift`、`SettingsView.swift`：新增腾讯云和 LLM 配置。

---

### Task 1：统一字幕模型与纯内存 Store

**文件：**
- 新建：`macos-app/Sources/Live/TranscriptModels.swift`
- 新建：`macos-app/Sources/Live/LiveTranscriptStore.swift`
- 新建测试：`macos-app/Tests/CallCaptureTests/LiveTranscriptStoreTests.swift`

**接口：**
- 产出：`TranscriptEvent`、`TranscriptUtterance`、`LiveConnectionState`。
- 产出：`@MainActor final class LiveTranscriptStore`，包含 `apply(_:)`、`context(endingAt:duration:)`、`copyText`、`clear()`。

- [ ] **步骤 1：先写失败测试**

覆盖同 ID 临时结果替换、最终结果只追加一次、未知说话人、30 秒边界保留完整句、忽略临时字幕、复制格式和 `clear()`。

```swift
@Test("30 秒上下文只包含已确认话语并保留跨界整句")
@MainActor func selectsContext() {
    let store = LiveTranscriptStore()
    store.apply(.confirmed(id: "a", speakerID: "1", text: "较早但跨界", startMS: 69_000, endMS: 71_000))
    store.apply(.partial(id: "p", speakerID: "2", text: "临时", startMS: 95_000, endMS: 99_000))
    store.apply(.confirmed(id: "b", speakerID: "2", text: "当前问题", startMS: 90_000, endMS: 100_000))
    #expect(store.context(endingAt: 100, duration: 30).map(\.id) == ["a", "b"])
}
```

- [ ] **步骤 2：运行并确认失败**

运行：`cd macos-app && swift test --filter LiveTranscriptStoreTests`  
预期：因类型不存在而编译失败。

- [ ] **步骤 3：实现最小模型和 Store**

`TranscriptUtterance` 使用毫秒时间戳和 `isFinal`；最终话语用 ID 字典去重并按 `startMS` 排序；标签按首次出现顺序映射为“发言人 N”；`context` 用 `endMS >= Int((endingAt-duration)*1000)` 选择最终话语。

- [ ] **步骤 4：运行测试并提交**

运行：`cd macos-app && swift test --filter LiveTranscriptStoreTests`  
预期：全部通过。

```bash
git add macos-app/Sources/Live macos-app/Tests/CallCaptureTests/LiveTranscriptStoreTests.swift
git commit -m "feat(live): add in-memory transcript store"
```

### Task 2：有界 PCM 缓冲区

**文件：**
- 新建：`macos-app/Sources/Live/PCMChunkBuffer.swift`
- 新建测试：`macos-app/Tests/CallCaptureTests/PCMChunkBufferTests.swift`

**接口：**
- 产出：`final class PCMChunkBuffer: @unchecked Sendable`。
- 方法：`push(_ data: Data) -> Int` 返回本次丢弃块数；`pop() -> Data?`；`finish()`；`clear()`。

- [ ] **步骤 1：写失败测试**

```swift
@Test("满载时丢弃最旧数据") func dropsOldest() {
    let buffer = PCMChunkBuffer(capacity: 2)
    #expect(buffer.push(Data([1])) == 0)
    #expect(buffer.push(Data([2])) == 0)
    #expect(buffer.push(Data([3])) == 1)
    #expect(buffer.pop() == Data([2]))
    #expect(buffer.pop() == Data([3]))
}
```

- [ ] **步骤 2：验证失败，实现并验证通过**

使用 `NSLock` 只保护固定容量数组；不得在锁内等待网络或调用 UI。运行：`cd macos-app && swift test --filter PCMChunkBufferTests`，预期通过。

- [ ] **步骤 3：提交**

```bash
git add macos-app/Sources/Live/PCMChunkBuffer.swift macos-app/Tests/CallCaptureTests/PCMChunkBufferTests.swift
git commit -m "feat(live): add bounded PCM buffer"
```

### Task 3：枚举并选择会议应用进程

**文件：**
- 新建：`macos-app/Sources/Capture/AudioProcessEnumerator.swift`
- 新建测试：`macos-app/Tests/CallCaptureTests/AudioProcessInfoTests.swift`
- 修改：`macos-app/Sources/App/ContentView.swift`

**接口：**
- 产出：`AudioProcessInfo(id: AudioObjectID, pid: pid_t, name: String, bundleID: String?)`。
- 产出：`AudioProcessEnumerator.processes() -> [AudioProcessInfo]`。

- [ ] **步骤 1：测试纯排序与过滤**

测试过滤当前进程、无效 PID、重复 PID，并按显示名称排序。把过滤逻辑放入可测试的 `normalize(_:currentPID:)`。

- [ ] **步骤 2：验证失败并实现枚举**

读取 `kAudioHardwarePropertyProcessObjectList`，再读取每个对象的 `kAudioProcessPropertyPID`；通过 `NSRunningApplication(processIdentifier:)` 取得名称和 bundle ID。运行对应测试，预期通过。

- [ ] **步骤 3：把菜单栏选择器改为会议应用 Picker 并提交**

空列表显示“未发现可捕获应用”；开始按钮在未选择时禁用；刷新时保留仍存在的 PID。

```bash
git add macos-app/Sources/Capture/AudioProcessEnumerator.swift macos-app/Sources/App/ContentView.swift macos-app/Tests/CallCaptureTests/AudioProcessInfoTests.swift
git commit -m "feat(capture): select an application audio process"
```

### Task 4：把音频采集改为指定进程的内存 PCM 输出

**文件：**
- 修改：`macos-app/Sources/Capture/AudioCaptureManager.swift`
- 新建测试：`macos-app/Tests/CallCaptureTests/PCMEncodingTests.swift`

**接口：**
- 新入口：`startLiveCapture(processObjectID: AudioObjectID, onPCM: @escaping @Sendable (Data) -> Void) async throws`。
- 现有录音入口暂时保留，避免一次改动破坏旧测试。

- [ ] **步骤 1：写 Float32 到 PCM16 的饱和转换测试**

验证 `[-1.5, -1, 0, 0.5, 1, 1.5]` 转成 `[-32768, -32768, 0, 16384, 32767, 32767]`。

- [ ] **步骤 2：验证失败并实现纯转换函数**

新增 `static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data`，使用 little-endian `Int16`，不执行日志或分配无限缓存。

- [ ] **步骤 3：实现指定进程 Tap**

使用 `CATapDescription(stereoMixdownOfProcesses: [processObjectID])` 替代全局排除列表；继续使用现有 aggregate device、downmix 和 `AVAudioConverter`，转换后调用 `onPCM`，不创建 `AudioFileWriter`。

- [ ] **步骤 4：验证现有捕获测试和新测试并提交**

运行：`cd macos-app && swift test --filter PCMEncodingTests && swift test --filter BufferSplitTests`，预期全部通过。

```bash
git add macos-app/Sources/Capture/AudioCaptureManager.swift macos-app/Tests/CallCaptureTests/PCMEncodingTests.swift
git commit -m "feat(capture): stream selected process audio in memory"
```

### Task 5：ASR 协议、腾讯事件解析和签名

**文件：**
- 新建：`macos-app/Sources/Live/LiveTranscriber.swift`
- 新建：`macos-app/Sources/Live/TencentTranscriptDecoder.swift`
- 新建：`macos-app/Sources/Live/TencentSigner.swift`
- 新建测试：`TencentTranscriptDecoderTests.swift`、`TencentSignerTests.swift`

**接口：**
- `LiveTranscriber.connect(configuration:)`、`send(_:)`、`events()`、`finish()`、`cancel()`。
- `TencentTranscriptDecoder.decode(_:) -> [TranscriptEvent]`。
- `TencentSigner.signedURL(configuration:timestamp:nonce:) throws -> URL`。

- [ ] **步骤 1：使用脱敏固定样例编写解析测试**

样例覆盖 `sentence_type=0/1`、`speaker_id=-1`、多句列表和服务端错误码；断言不会把原始 JSON放入错误描述。

- [ ] **步骤 2：使用腾讯云官方签名示例编写确定性签名测试**

固定 AppID、SecretId、测试 SecretKey、时间戳和 nonce，断言 URL 查询参数编码和 HMAC-SHA1 Base64 结果完全一致。

- [ ] **步骤 3：实现解析、签名并运行测试**

运行：`cd macos-app && swift test --filter TencentTranscriptDecoderTests && swift test --filter TencentSignerTests`，预期通过。

- [ ] **步骤 4：提交**

```bash
git add macos-app/Sources/Live macos-app/Tests/CallCaptureTests/TencentTranscriptDecoderTests.swift macos-app/Tests/CallCaptureTests/TencentSignerTests.swift
git commit -m "feat(asr): add Tencent transcript decoding and signing"
```

### Task 6：腾讯云实时 WebSocket Transcriber

**文件：**
- 新建：`macos-app/Sources/Live/TencentLiveTranscriber.swift`
- 新建测试：`macos-app/Tests/CallCaptureTests/TencentLiveTranscriberTests.swift`

**接口：**
- 实现任务 5 的 `LiveTranscriber`。
- 注入 `URLSession` 和 signer，生产环境不允许在日志中打印完整 URL。

- [ ] **步骤 1：用自定义 `URLProtocol`/传输协议替身写失败测试**

覆盖连接、每 200 ms PCM 发送、事件产生、正常结束、服务端错误、取消以及最多三次指数退避重连。

- [ ] **步骤 2：实现 Actor 状态机**

状态限定为 `idle/connecting/live/reconnecting/finished/failed`；重复 `connect` 和结束后 `send` 必须抛出明确错误；事件通过单一 `AsyncThrowingStream` 输出。

- [ ] **步骤 3：运行测试并提交**

运行：`cd macos-app && swift test --filter TencentLiveTranscriberTests`，预期通过。

```bash
git add macos-app/Sources/Live/TencentLiveTranscriber.swift macos-app/Tests/CallCaptureTests/TencentLiveTranscriberTests.swift
git commit -m "feat(asr): stream audio to Tencent ASR"
```

### Task 7：实时会议 Coordinator 和生命周期

**文件：**
- 新建：`macos-app/Sources/Live/LiveMeetingCoordinator.swift`
- 新建测试：`macos-app/Tests/CallCaptureTests/LiveMeetingCoordinatorTests.swift`
- 修改：`macos-app/Sources/App/CallCaptureApp.swift`
- 修改：`macos-app/Sources/App/AppDelegate.swift`

**接口：**
- `start(process:) async`、`stop() async`、`clearAndClose() async`、`shutdown()`。
- 状态：`idle/connecting/live/reconnecting/review/error`。

- [ ] **步骤 1：用 FakeCapture 和 FakeTranscriber 写状态测试**

覆盖开始、手动停止、进程退出、ASR 重试耗尽、LLM 无关性、开始新会话先清空、退出清空。

- [ ] **步骤 2：实现编排**

PCM 回调只 `push` 到任务 2 队列；独立发送 Task 从队列取数据；独立事件 Task 更新 `LiveTranscriptStore`；停止顺序为停止采集、结束队列、结束 ASR、进入 review。

- [ ] **步骤 3：接入 AppModel 与退出清理，运行测试并提交**

```bash
git add macos-app/Sources/Live/LiveMeetingCoordinator.swift macos-app/Sources/App/CallCaptureApp.swift macos-app/Sources/App/AppDelegate.swift macos-app/Tests/CallCaptureTests/LiveMeetingCoordinatorTests.swift
git commit -m "feat(live): coordinate realtime meeting lifecycle"
```

### Task 8：原生悬浮字幕窗口

**文件：**
- 新建：`macos-app/Sources/UI/SubtitlePanelController.swift`
- 新建：`macos-app/Sources/UI/LiveSubtitleView.swift`
- 新建测试：`macos-app/Tests/CallCaptureTests/SubtitlePresentationTests.swift`

**接口：**
- `SubtitlePanelController.show(store:coordinator:)`、`setMousePassthrough(_:)`、`closeAndClear()`。

- [ ] **步骤 1：测试纯展示模型**

验证 live 状态只返回最近三条最终字幕加一条临时字幕，review 返回全部最终字幕，复制文本不含临时内容。

- [ ] **步骤 2：实现 `NSPanel`**

配置 `.borderless`、`.nonactivatingPanel`、`level = .floating`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`；锁定时设置 `ignoresMouseEvents = true`；默认位于当前屏幕底部中央。

- [ ] **步骤 3：实现 SwiftUI 字幕/查看界面并人工验证**

验证不抢焦点、拖动、缩放、字号、透明度、鼠标穿透、多显示器、Space 和全屏会议应用。

- [ ] **步骤 4：提交**

```bash
git add macos-app/Sources/UI/SubtitlePanelController.swift macos-app/Sources/UI/LiveSubtitleView.swift macos-app/Tests/CallCaptureTests/SubtitlePresentationTests.swift
git commit -m "feat(ui): add floating live subtitle panel"
```

### Task 9：可配置 LLM 与流式客户端

**文件：**
- 新建：`macos-app/Sources/Assistant/LLMConfiguration.swift`
- 新建：`macos-app/Sources/Assistant/OpenAICompatibleClient.swift`
- 新建测试：`LLMConfigurationTests.swift`、`OpenAICompatibleClientTests.swift`
- 修改：`SettingsManager.swift`、`SettingsView.swift`

**接口：**
- 预设：OpenAI、OpenRouter、DeepSeek、Ollama、自定义。
- `stream(messages:configuration:) -> AsyncThrowingStream<String, Error>`。

- [ ] **步骤 1：测试预设、URL 校验、可选本地 Key 和 Keychain 账户名**
- [ ] **步骤 2：用模拟 SSE 测试 `data:` 分片、`[DONE]`、HTTP 401/429、取消和超时**
- [ ] **步骤 3：实现配置、客户端与设置 UI**

请求只包含 `model/messages/temperature/max_tokens/stream=true`；日志只记录状态码和错误类别。连接测试发送固定文本 `Reply with OK.`，不得读取字幕 Store。

- [ ] **步骤 4：运行测试并提交**

```bash
git add macos-app/Sources/Assistant macos-app/Sources/Settings macos-app/Tests/CallCaptureTests/LLMConfigurationTests.swift macos-app/Tests/CallCaptureTests/OpenAICompatibleClientTests.swift
git commit -m "feat(assistant): add configurable streaming LLM client"
```

### Task 10：30 秒会议助手与助手窗口

**文件：**
- 新建：`macos-app/Sources/Assistant/MeetingAssistant.swift`
- 新建：`macos-app/Sources/UI/AssistantPanelController.swift`
- 新建：`macos-app/Sources/UI/AssistantView.swift`
- 新建：`macos-app/Sources/Assistant/GlobalShortcutManager.swift`
- 新建测试：`macos-app/Tests/CallCaptureTests/MeetingAssistantTests.swift`

- [ ] **步骤 1：测试 Prompt、编辑后发送、单任务取消和无字幕拒绝发送**

断言默认读取 `store.context(endingAt: clock.now, duration: 30)`，按时间顺序带说话人标签，且替换后的编辑文本才进入网络请求。

- [ ] **步骤 2：实现 `MeetingAssistant` 和流式回复状态**

状态为 `idle/composing/generating/completed/failed`；新请求先取消旧 Task；`clear()` 取消任务并清空上下文和回复。

- [ ] **步骤 3：实现非激活助手 Panel、快捷指令和复制操作**

提供“给出想法”“组织发言”“分析风险”“追问问题”和自定义指令。`GlobalShortcutManager.register(keyCode:modifiers:handler:)` 使用 Carbon `RegisterEventHotKey` 注册快捷键，并在重新配置或退出时调用 `UnregisterEventHotKey`；默认 `⌥Space`，允许在设置中修改。

- [ ] **步骤 4：验证 LLM 故障不影响 coordinator 并提交**

```bash
git add macos-app/Sources/Assistant/MeetingAssistant.swift macos-app/Sources/UI/AssistantPanelController.swift macos-app/Sources/UI/AssistantView.swift macos-app/Tests/CallCaptureTests/MeetingAssistantTests.swift
git commit -m "feat(assistant): add 30-second meeting copilot"
```

### Task 11：主界面整合、隐私文案与端到端验证

**文件：**
- 修改：`macos-app/Sources/App/ContentView.swift`
- 修改：`macos-app/Sources/App/CallCaptureApp.swift`
- 修改：`macos-app/Sources/Settings/SettingsView.swift`
- 修改：`README.md`
- 修改：`docs/DEVELOPMENT.md`

- [ ] **步骤 1：将主界面收敛为应用选择、开始/停止、字幕状态、助手和设置入口**

移除主流程中的麦克风选择、录音类型、会话列表和会后处理入口；旧模块可以暂时保留编译，但新实时流程不得调用它们。

- [ ] **步骤 2：加入明确隐私文案**

开始前显示“所选应用音频会发送到腾讯云 ASR；只有手动提交时，最近 30 秒字幕才会发送到所配置的 LLM；内容不会保存到本地”。

- [ ] **步骤 3：运行全部自动化验证**

运行：`cd macos-app && swift test`，预期全部通过。  
运行：`cd macos-app && swift build`，预期构建成功。  
运行：`git diff --check`，预期无输出。

- [ ] **步骤 4：完成真实应用验证清单**

依次验证腾讯会议、Zoom、飞书；其他音频不被捕获；中英文混说；至少两名远端发言人；断网和恢复；会议应用退出；LLM 401/429/超时；关闭后使用 `find ~/Library/Application\ Support/CallCapture -type f` 确认没有本次音频、字幕或回复文件。

- [ ] **步骤 5：提交最终整合**

```bash
git add macos-app/Sources/App macos-app/Sources/Settings README.md docs/DEVELOPMENT.md
git commit -m "feat: ship realtime meeting overlay assistant"
```

## 实施完成条件

- 任务 1–11 的测试和提交全部完成。
- `swift test` 与 `swift build` 在匹配的 Xcode/SDK 工具链中通过。
- 手工验证证明只捕获指定应用、不打开麦克风、不落盘会议内容。
- ASR、字幕和 LLM 失败路径均有明确 UI 状态。
- LLM 取消、超时或错误不会停止实时字幕。
- 用户关闭窗口、开始新会议或退出应用后，内存字幕和助手内容均被清除。

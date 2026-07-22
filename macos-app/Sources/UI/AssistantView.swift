import SwiftUI

/// Editable prompt composer and streaming response surface for one meeting.
@available(macOS 14.2, *)
@MainActor
struct AssistantView: View {
    let assistant: MeetingAssistant
    let onCopy: (String) -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    @State private var customInstruction = ""

    var body: some View {
        @Bindable var assistant = assistant

        VStack(alignment: .leading, spacing: 14) {
            header

            Text("只有点击发送后，下方编辑内容才会发送给已配置的 LLM。内容不会保存在本地。")
                .font(.caption)
                .foregroundStyle(.secondary)

            quickActions

            GroupBox("发送内容（可编辑）") {
                TextEditor(text: $assistant.draft)
                    .font(.body)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
            }

            composerActions

            Divider()

            response
        }
        .padding(18)
        .frame(minWidth: 400, minHeight: 420)
        .background(.regularMaterial)
    }
}

@available(macOS 14.2, *)
@MainActor
private extension AssistantView {
    var header: some View {
        HStack {
            Label("会议助手", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
            .help("打开助手设置")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭并清空")
        }
    }

    var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(AssistantQuickInstruction.allCases.filter { $0 != .custom }) { action in
                    Button(action.title) {
                        assistant.compose(instruction: action.instruction)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 8) {
                TextField("自定义指令", text: $customInstruction)
                    .textFieldStyle(.roundedBorder)
                Button(AssistantQuickInstruction.custom.title) {
                    assistant.compose(instruction: customInstruction)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    var composerActions: some View {
        HStack {
            stateLabel
            Spacer()

            if assistant.state == .generating {
                Button("取消", role: .cancel) {
                    assistant.cancelGeneration()
                }
            } else if assistant.state == .failed, !assistant.contextText.isEmpty {
                Button("重试") {
                    assistant.submit()
                }
            }

            Button("发送") {
                assistant.submit()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                assistant.state == .generating
                    || assistant.contextText.isEmpty
                    || assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    @ViewBuilder
    var stateLabel: some View {
        switch assistant.state {
        case .idle:
            Text("选择指令以载入最近 30 秒字幕")
                .foregroundStyle(.secondary)
        case .composing:
            Text("发送前可编辑或删除任何内容")
                .foregroundStyle(.secondary)
        case .generating:
            Label("正在生成…", systemImage: "ellipsis")
                .foregroundStyle(.secondary)
        case .completed:
            Label("已完成", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed:
            Label(assistant.errorMessage ?? "请求失败", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    var response: some View {
        GroupBox {
            ScrollView {
                Text(assistant.reply.isEmpty ? responsePlaceholder : assistant.reply)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .foregroundStyle(assistant.reply.isEmpty ? .secondary : .primary)
            }
            .frame(maxHeight: .infinity)
        } label: {
            HStack {
                Text("回复")
                Spacer()
                Button {
                    onCopy(assistant.reply)
                } label: {
                    Label("复制回复", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .disabled(assistant.reply.isEmpty)
                .help("复制回复")
            }
        }
    }

    var responsePlaceholder: String {
        assistant.state == .generating ? "等待模型回复…" : "回复将在这里流式显示。"
    }
}

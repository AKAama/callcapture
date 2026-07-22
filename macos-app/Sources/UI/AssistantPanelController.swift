import AppKit
import SwiftUI

/// Owns the assistant's non-activating, cross-Space floating panel.
@available(macOS 14.2, *)
@MainActor
final class AssistantPanelController: NSObject, NSWindowDelegate {
    private enum Layout {
        static let defaultSize = NSSize(width: 520, height: 600)
        static let minimumSize = NSSize(width: 400, height: 420)
        static let edgeMargin: CGFloat = 28
    }

    private var panel: NSPanel?
    private weak var assistant: MeetingAssistant?
    private var openSettings: (() -> Void)?

    func show(
        assistant: MeetingAssistant,
        openSettings: @escaping () -> Void = {}
    ) {
        self.assistant = assistant
        self.openSettings = openSettings

        let rootView = AssistantView(
            assistant: assistant,
            onCopy: Self.copyToPasteboard,
            onOpenSettings: openSettings,
            onClose: { [weak self] in self?.closeAndClear() }
        )

        if let panel {
            panel.contentView = transparentHostingView(rootView: rootView)
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Layout.defaultSize),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "会议助手"
        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = Layout.minimumSize
        panel.contentView = transparentHostingView(rootView: rootView)
        positionNearTopRight(panel)

        self.panel = panel
        panel.orderFrontRegardless()
    }

    func closeAndClear() {
        assistant?.clear()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.delegate = nil
        panel = nil
        assistant = nil
        openSettings = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSPanel === panel else { return }
        closeAndClear()
    }
}

@available(macOS 14.2, *)
@MainActor
private extension AssistantPanelController {
    func transparentHostingView<Content: View>(rootView: Content) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        return hostingView
    }

    func positionNearTopRight(_ panel: NSPanel) {
        let screen = screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let width = min(Layout.defaultSize.width, visibleFrame.width)
        let height = min(Layout.defaultSize.height, visibleFrame.height)
        let origin = NSPoint(
            x: visibleFrame.maxX - width - Layout.edgeMargin,
            y: visibleFrame.maxY - height - Layout.edgeMargin
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    }

    func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }

    static func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

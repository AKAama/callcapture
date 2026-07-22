import AppKit
import SwiftUI

/// Owns the native subtitle panel without coupling its lifecycle to a SwiftUI scene.
@available(macOS 14.2, *)
@MainActor
final class SubtitlePanelController: NSObject, NSWindowDelegate {
    private enum Layout {
        static let defaultSize = NSSize(width: 680, height: 270)
        static let minimumSize = NSSize(width: 420, height: 190)
        static let bottomMargin: CGFloat = 36
    }

    private let settings = SubtitlePanelSettings()
    private var panel: NSPanel?
    private weak var store: LiveTranscriptStore?
    private weak var coordinator: LiveMeetingCoordinator?

    /// Displays (or refreshes) the single subtitle panel for a live meeting.
    func show(store: LiveTranscriptStore, coordinator: LiveMeetingCoordinator) {
        self.store = store
        self.coordinator = coordinator

        let rootView = LiveSubtitleView(
            store: store,
            coordinator: coordinator,
            settings: settings,
            onCopy: { text in
                Self.copyToPasteboard(text)
            },
            onClear: { [weak self] in
                self?.closeAndClear()
            },
            onMousePassthroughChange: { [weak self] enabled in
                self?.setMousePassthrough(enabled)
            }
        )

        if let panel {
            panel.contentView = transparentHostingView(rootView: rootView)
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Layout.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = Layout.minimumSize
        panel.ignoresMouseEvents = settings.isMousePassthrough
        panel.contentView = transparentHostingView(rootView: rootView)

        positionAtBottomCenter(panel)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    /// Enables click-through while locked. A menu-bar control can call this
    /// again with `false`, because a locked panel cannot receive its own clicks.
    func setMousePassthrough(_ enabled: Bool) {
        settings.isMousePassthrough = enabled
        panel?.ignoresMouseEvents = enabled
    }

    /// Immediately hides the panel, then asks the coordinator to cancel all
    /// live work and clear the in-memory transcript.
    func closeAndClear() {
        let coordinator = coordinator

        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.delegate = nil
        panel = nil
        store = nil
        self.coordinator = nil
        settings.isMousePassthrough = false

        Task { @MainActor in
            await coordinator?.clearAndClose()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSPanel === panel else { return }
        closeAndClear()
    }
}

@available(macOS 14.2, *)
@MainActor
private extension SubtitlePanelController {
    func transparentHostingView<Content: View>(rootView: Content) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        return hostingView
    }

    func positionAtBottomCenter(_ panel: NSPanel) {
        let screen = screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let width = min(Layout.defaultSize.width, visibleFrame.width)
        let height = min(Layout.defaultSize.height, visibleFrame.height)
        let origin = NSPoint(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + min(Layout.bottomMargin, max(0, visibleFrame.height - height))
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

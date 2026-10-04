import AppKit
import SwiftUI

private final class PermissionPanel: NSPanel {
    var allowsFocus = false
    override var canBecomeKey: Bool { allowsFocus }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PermissionPresenter {
    private weak var model: AppModel?
    private let panel: PermissionPanel
    init(model: AppModel) {
        self.model = model
        panel = PermissionPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 300),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }
    func show() {
        guard let model else { return }
        panel.allowsFocus = true
        panel.title = String(localized: "Use Typo Bouncer in other apps")
        setContent(PermissionSetupView(gate: model.accessibility, close: { [weak self] in self?.hide() }))
        // Setup has no captured selection to preserve; make its buttons keyboard-accessible.
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    private func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 580, height: 1)
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        panel.contentView = host
        panel.setContentSize(NSSize(width: 580, height: max(150, fitting.height)))
        if !panel.isVisible { panel.center() }
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil); panel.allowsFocus = false }
}

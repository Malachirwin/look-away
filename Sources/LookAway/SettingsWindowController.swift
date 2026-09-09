import AppKit
import SwiftUI

/// Hosts the settings panel in a plain, single-instance window. The app has no
/// Dock icon, so opening it also has to bring the app forward.
@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Look Away Settings"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        // The panel scrolls, so it has no natural height to fit to. Open at a
        // size that shows both sections expanded and let it be resized.
        window.setContentSize(NSSize(width: SettingsView.width, height: 620))
        window.contentMinSize = NSSize(width: SettingsView.width, height: 320)
        window.contentMaxSize = NSSize(width: SettingsView.width, height: .greatestFiniteMagnitude)
        return window
    }
}

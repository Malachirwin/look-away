import AppKit
import SwiftUI

/// Hosts the settings panel in a plain, single-instance window. The app has no
/// Dock icon or main menu, so opening it has to bring the app forward and the
/// window has to handle its own close shortcuts.
@MainActor
final class SettingsWindowController {
    private static let frameName = "Settings"

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = SettingsWindow(contentViewController: hosting)
        window.title = "Look Away Settings"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        // The panel scrolls, so it has no natural height to fit to. Open at a
        // size that shows both sections expanded and let it be resized.
        window.setContentSize(NSSize(width: SettingsView.width, height: 620))
        window.contentMinSize = NSSize(width: SettingsView.width, height: 320)
        window.contentMaxSize = NSSize(width: SettingsView.width, height: .greatestFiniteMagnitude)
        // Reopen where the user left it; only the very first open is centered.
        // A stale saved height is harmless now that the content scrolls.
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }
}

/// With no main menu there is no File > Close, so Esc and ⌘W are handled here.
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

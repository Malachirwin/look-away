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
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.setContentSize(hosting.view.fittingSize)
        // Reopen where the user left it; only the very first open is centered.
        // The saved size is stale whenever the content has changed, so it is
        // reset to fit.
        if window.setFrameUsingName(Self.frameName) {
            window.setContentSize(hosting.view.fittingSize)
        } else {
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

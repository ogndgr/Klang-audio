import AppKit
import AudioToolbox
import CoreAudioKit

/// Hosts the plugin's own view (via AUAudioUnit.requestViewController) in a window.
/// The view controller is retained and the window is reused across opens for the
/// same effect instance — re-requesting a view from a JUCE AU returns an empty
/// view, so we request once and just re-show.
final class PluginWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var viewController: NSViewController?
    private weak var builtFor: AUAudioUnit?
    private var onClose: (() -> Void)?

    func show(for unit: AUAudioUnit, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        if let win = window, builtFor === unit {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        rebuild(for: unit)
    }

    private func rebuild(for unit: AUAudioUnit) {
        discard()
        unit.requestViewController { [weak self] vc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let content: NSView = vc?.view ?? Self.fallbackView()
                if content.bounds.isEmpty {
                    content.setFrameSize(NSSize(width: 720, height: 480))
                }
                let win = NSWindow(contentRect: content.bounds,
                                   styleMask: [.titled, .closable],
                                   backing: .buffered, defer: false)
                win.title = "beyerdynamic Headphone Lab"
                win.contentView = content
                win.isReleasedWhenClosed = false
                win.delegate = self
                win.center()
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.viewController = vc   // retain so the view stays valid
                self.builtFor = unit
                self.window = win
            }
        }
    }

    /// Red-button close hides the window (keeps the view) so it can reopen.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        sender.orderOut(nil)
        return false
    }

    /// Fully tear down — call when the effect instance is going away.
    func discard() {
        if let win = window {
            win.delegate = nil
            win.close()
        }
        window = nil
        viewController = nil
        builtFor = nil
    }

    private static func fallbackView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        let label = NSTextField(labelWithString: "Bu plugin bir görsel arayüz sağlamıyor.")
        label.frame = NSRect(x: 20, y: 50, width: 320, height: 20)
        v.addSubview(label)
        return v
    }
}

import AppKit
import AudioToolbox

/// Objective-C factory protocol every Audio Unit Cocoa view class conforms to
/// (`<AudioUnit/AUCocoaUIView.h>`). Declared here so we can message a plugin's
/// view factory without linking the deprecated umbrella header.
@objc private protocol AUCocoaUIBase {
    @objc(uiViewForAudioUnit:withSize:)
    func uiView(forAudioUnit au: AudioUnit, withSize inSize: NSSize) -> NSView
}

/// Hosts the plugin's Cocoa view (kAudioUnitProperty_CocoaUI) for the SAME v2 audio
/// unit that renders audio. Requesting the v3 view controller instead re-touches the
/// shared JUCE AU state and silences the v2 render path, so we deliberately stay on v2.
/// The window is reused across opens — re-instantiating a JUCE view returns an empty one.
final class PluginWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(for unit: AudioUnit, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        if let win = window {
            klangDbg("show: reuse existing window/view")   // TEMP
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        klangDbg("show: creating cocoa view")   // TEMP
        let content = Self.cocoaView(for: unit) ?? Self.fallbackView()
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
        self.window = win
    }

    /// Red-button close hides the window (keeps the view) so it can reopen.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        klangDbg("windowShouldClose: hiding window")   // TEMP
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
    }

    /// Build the plugin's own Cocoa view from the v2 audio unit, or nil if it has none.
    private static func cocoaView(for au: AudioUnit) -> NSView? {
        var size = UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size)
        let infoPtr = UnsafeMutablePointer<AudioUnitCocoaViewInfo>.allocate(capacity: 1)
        defer { infoPtr.deallocate() }
        guard AudioUnitGetProperty(au, kAudioUnitProperty_CocoaUI,
                                   kAudioUnitScope_Global, 0, infoPtr, &size) == noErr
        else { return nil }
        let info = infoPtr.pointee
        let bundleURL = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String
        guard !className.isEmpty,
              let bundle = Bundle(url: bundleURL), bundle.load(),
              let viewClass = bundle.classNamed(className) as? NSObject.Type
        else { return nil }

        let factory = viewClass.init()
        let selector = #selector(AUCocoaUIBase.uiView(forAudioUnit:withSize:))
        guard factory.responds(to: selector) else { return nil }
        return unsafeBitCast(factory, to: AUCocoaUIBase.self)
            .uiView(forAudioUnit: au, withSize: NSSize(width: 720, height: 480))
    }

    private static func fallbackView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        let label = NSTextField(labelWithString: "This plugin doesn't provide a visual interface.")
        label.frame = NSRect(x: 20, y: 50, width: 320, height: 20)
        v.addSubview(label)
        return v
    }
}

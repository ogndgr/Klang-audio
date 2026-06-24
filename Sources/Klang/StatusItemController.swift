import AppKit
import ServiceManagement

final class StatusItemController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller = AppController()
    private var pluginWindow: PluginWindowController?

    func install() {
        controller.recoverIfNeeded()
        controller.onSafety = { [weak self] reason in
            self?.refresh()
            self?.alert("⚠️ \(reason).\n\nKlang turned itself off for safety. Keep Klang off while using a DAW (Logic, etc.); add the correction as a plugin inside the DAW instead.")
        }
        controller.observeDeviceChanges { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    private func updateIcon() {
        let name = controller.isActive ? "waveform.circle.fill" : "waveform.circle"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Klang")
    }

    private func refresh() {
        if !controller.isActive {
            pluginWindow?.discard()   // effect instance is gone; its view is invalid
            pluginWindow = nil
        }
        updateIcon()
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: controller.isActive ? "Active — turn off" : "Turn on",
                                action: #selector(toggleActive), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let bypass = NSMenuItem(title: "Bypass", action: #selector(toggleBypass), keyEquivalent: "")
        bypass.target = self
        bypass.state = controller.bypass ? .on : .off
        bypass.isEnabled = controller.isActive
        menu.addItem(bypass)

        menu.addItem(.separator())

        let pluginUI = NSMenuItem(title: "Open beyerdynamic Lab…",
                                  action: #selector(openPluginUI), keyEquivalent: "")
        pluginUI.target = self
        pluginUI.isEnabled = controller.isActive
        menu.addItem(pluginUI)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func toggleActive() {
        if controller.isActive {
            controller.deactivate()
            refresh()
        } else {
            controller.activate { [weak self] result in
                DispatchQueue.main.async {
                    if case .failure(let e) = result { self?.alert("Couldn't open: \(e)") }
                    self?.refresh()
                }
            }
        }
    }

    @objc private func toggleBypass() {
        controller.bypass.toggle()
        refresh()
    }

    @objc private func openPluginUI() {
        guard let au = controller.effectAU else { return }
        if pluginWindow == nil { pluginWindow = PluginWindowController() }
        pluginWindow?.show(for: au) { [weak self] in self?.controller.saveStateNow() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't set Open at Login: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func quit() {
        pluginWindow?.discard()
        controller.deactivate()
        NSApp.terminate(nil)
    }

    private func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Klang"
        a.informativeText = msg
        a.runModal()
    }
}

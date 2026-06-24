import AppKit
import ServiceManagement

final class StatusItemController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller = AppController()
    private var pluginWindow: PluginWindowController?

    func install() {
        controller.recoverIfNeeded()
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
        updateIcon()
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: controller.isActive ? "Aktif — kapat" : "Aç",
                                action: #selector(toggleActive), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let bypass = NSMenuItem(title: "Bypass", action: #selector(toggleBypass), keyEquivalent: "")
        bypass.target = self
        bypass.state = controller.bypass ? .on : .off
        bypass.isEnabled = controller.isActive
        menu.addItem(bypass)

        menu.addItem(.separator())

        let pluginUI = NSMenuItem(title: "beyerdynamic Lab'i aç…",
                                  action: #selector(openPluginUI), keyEquivalent: "")
        pluginUI.target = self
        pluginUI.isEnabled = controller.isActive
        menu.addItem(pluginUI)

        let login = NSMenuItem(title: "Açılışta başlat", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let quit = NSMenuItem(title: "Çıkış", action: #selector(quit), keyEquivalent: "q")
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
                    if case .failure(let e) = result { self?.alert("Açılamadı: \(e)") }
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
        pluginWindow = PluginWindowController()
        pluginWindow?.show(for: au) { [weak self] in self?.controller.saveStateNow() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Açılışta başlat ayarlanamadı: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func quit() {
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

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
        menu.autoenablesItems = false   // manage enabled state explicitly

        let active = controller.isActive

        let toggle = NSMenuItem(title: active ? "Active — turn off" : "Turn on",
                                action: #selector(toggleActive), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let bypass = NSMenuItem(title: "Bypass", action: #selector(toggleBypass), keyEquivalent: "")
        bypass.target = self
        bypass.state = controller.bypass ? .on : .off
        bypass.isEnabled = active
        menu.addItem(bypass)

        menu.addItem(.separator())
        menu.addItem(makeDeviceItem())
        menu.addItem(makeProfileItem(active: active))
        menu.addItem(.separator())

        let pluginUI = NSMenuItem(title: "Open beyerdynamic Lab…",
                                  action: #selector(openPluginUI), keyEquivalent: "")
        pluginUI.target = self
        pluginUI.isEnabled = active
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

    /// "Output Device" submenu — always available; picks the physical target Klang
    /// routes to. "Automatic" follows the system default output.
    private func makeDeviceItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let target = controller.targetDeviceUID

        let auto = NSMenuItem(title: "Automatic (system default)",
                              action: #selector(chooseDevice(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = nil
        auto.state = (target == nil) ? .on : .off
        submenu.addItem(auto)
        submenu.addItem(.separator())

        for dev in controller.selectableOutputs() {
            let mi = NSMenuItem(title: dev.name, action: #selector(chooseDevice(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = dev.uid
            mi.state = (dev.uid == target) ? .on : .off
            submenu.addItem(mi)
        }
        parent.submenu = submenu
        return parent
    }

    /// "Profile" submenu — enabled only while active (create/edit needs the live effect).
    private func makeProfileItem(active: Bool) -> NSMenuItem {
        let parent = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        parent.isEnabled = active
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let activePID = controller.activeProfileID

        for p in controller.profiles() {
            let mi = NSMenuItem(title: p.name, action: #selector(chooseProfile(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = p.id
            mi.state = (p.id == activePID) ? .on : .off
            mi.isEnabled = active
            submenu.addItem(mi)
        }
        if !controller.profiles().isEmpty { submenu.addItem(.separator()) }

        let newItem = NSMenuItem(title: "New from current…", action: #selector(newProfile), keyEquivalent: "")
        newItem.target = self
        newItem.isEnabled = active
        submenu.addItem(newItem)

        let renameItem = NSMenuItem(title: "Rename…", action: #selector(renameProfile), keyEquivalent: "")
        renameItem.target = self
        renameItem.isEnabled = active && activePID != nil
        submenu.addItem(renameItem)

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteProfile), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = active && activePID != nil
        submenu.addItem(deleteItem)

        parent.submenu = submenu
        return parent
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

    @objc private func chooseDevice(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String   // nil = Automatic
        controller.setOutputDevice(uid) { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let e) = result { self?.alert("Couldn't switch device: \(e)") }
                self?.refresh()
            }
        }
    }

    @objc private func chooseProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller.selectProfile(id: id)
        refresh()
    }

    @objc private func newProfile() {
        guard let name = promptText(title: "New profile",
                                    message: "Save the current EQ as a named profile for this device:",
                                    defaultValue: ""), !name.isEmpty else { return }
        controller.newProfileFromCurrent(name: name)
        refresh()
    }

    @objc private func renameProfile() {
        guard let id = controller.activeProfileID else { return }
        guard let name = promptText(title: "Rename profile", message: "New name:",
                                    defaultValue: controller.activeProfileName ?? ""),
              !name.isEmpty else { return }
        controller.renameProfile(id: id, to: name)
        refresh()
    }

    @objc private func deleteProfile() {
        guard let id = controller.activeProfileID else { return }
        let name = controller.activeProfileName ?? "this profile"
        let a = NSAlert()
        a.messageText = "Delete “\(name)”?"
        a.informativeText = "The saved EQ snapshot for this profile will be removed."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            controller.deleteProfile(id: id)
            refresh()
        }
    }

    /// Modal text prompt (NSAlert + text field). Returns nil on cancel.
    private func promptText(title: String, message: String, defaultValue: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultValue
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func openPluginUI() {
        guard let au = controller.effectAudioUnit else { return }
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

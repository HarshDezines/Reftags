import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: KeyMonitor!
    private var libraryWindow: NSWindow?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        monitor = KeyMonitor(store: RefStore.shared)
        monitor.onQuickAdd = { QuickAddController.shared.show() }
        startMonitor()

        // delete old unused tags now and every few hours
        RefStore.shared.cleanUpUnused()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            RefStore.shared.cleanUpUnused()
        }

        if RefStore.shared.entries.isEmpty || !AXIsProcessTrusted() { openLibrary() }
    }

    // MARK: keyboard monitor + permission

    private func startMonitor() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if trusted && monitor.start() { return }
        // Wait for the user to tick RefTags in System Settings → Privacy → Accessibility.
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if AXIsProcessTrusted() && self.monitor.start() { t.invalidate() }
        }
    }

    // MARK: menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "person.crop.square.filled.and.at.rectangle",
                                 accessibilityDescription: "RefTags")
                ?? NSImage(systemSymbolName: "person.crop.square", accessibilityDescription: "RefTags") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "R"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "⚠️ Allow Accessibility permission…", action: #selector(openPermissions), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        add(menu, "Open Library", #selector(openLibrary))
        let quick = add(menu, "Add Copied Image as Tag   \(Hotkeys.quickAddLabel)", #selector(quickAdd))
        quick.isEnabled = true
        menu.addItem(.separator())

        let count = RefStore.shared.entries.count
        let info = NSMenuItem(title: "\(count) character\(count == 1 ? "" : "s") saved · \(RefStore.shared.storageText)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        let on = add(menu, "Enabled", #selector(toggleEnabled))
        on.state = Settings.enabled ? .on : .off
        let label = add(menu, "Name Label Under Pasted Images", #selector(toggleLabel))
        label.state = Settings.labelImages ? .on : .off
        if #available(macOS 13.0, *) {
            let login = add(menu, "Open at Login", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        let autoItem = NSMenuItem(title: "Auto-Delete Unused Tags", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for days in [3, 7, 14, 30, 0] {
            let it = NSMenuItem(title: days == 0 ? "Never" : "After \(days) days",
                                action: #selector(setAutoDelete(_:)), keyEquivalent: "")
            it.target = self
            it.tag = days
            it.state = Settings.autoDeleteDays == days ? .on : .off
            sub.addItem(it)
        }
        autoItem.submenu = sub
        menu.addItem(autoItem)
        menu.addItem(.separator())
        add(menu, "Clear All Tags…", #selector(clearAll))
        add(menu, "Show Images Folder", #selector(showFolder))
        add(menu, "Quit RefTags", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc func openLibrary() {
        if libraryWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "RefTags — Character References"
            w.contentView = NSHostingView(rootView: LibraryView())
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("RefTagsLibrary")
            libraryWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quickAdd() { QuickAddController.shared.show() }
    @objc private func toggleEnabled() { Settings.enabled.toggle() }
    @objc private func toggleLabel() { Settings.labelImages.toggle() }
    @objc private func showFolder() { NSWorkspace.shared.open(RefStore.shared.dir) }
    @objc private func setAutoDelete(_ sender: NSMenuItem) {
        Settings.autoDeleteDays = sender.tag
        RefStore.shared.cleanUpUnused()
    }

    @objc func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all saved characters?"
        alert.informativeText = "This removes every tag and its images (\(RefStore.shared.storageText))."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { RefStore.shared.clearAll() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        if #available(macOS 13.0, *) {
            let svc = SMAppService.mainApp
            if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
        }
    }

    // MARK: main menu (so ⌘C / ⌘V / ⌘A work in text fields)

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit RefTags", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

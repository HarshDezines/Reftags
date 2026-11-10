import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: KeyMonitor!
    private var libraryWindow: NSWindow?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Installer.moveToApplicationsIfNeeded() { return }
        setupMainMenu()
        setupStatusItem()

        monitor = KeyMonitor(store: RefStore.shared)
        monitor.onQuickAdd = { QuickAddController.shared.handleHotkey() }
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
        if AXIsProcessTrusted() && monitor.start() { return }
        // Not allowed yet: clear stale entries from older versions, then ask for this one.
        Installer.requestAccessibility(openSettings: false)
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
        add(menu, "Add Face (copied image or screen area)   \(Hotkeys.quickAddLabel)", #selector(quickAdd))
        menu.addItem(.separator())

        // Projects
        let store = RefStore.shared
        let projItem = NSMenuItem(title: "Project: \(store.project.name)\(store.project.shared ? "  (shared)" : "")",
                                  action: nil, keyEquivalent: "")
        let projMenu = NSMenu()
        for p in Projects.all {
            let it = NSMenuItem(title: p.name + (p.shared ? "  (shared)" : ""),
                                action: #selector(switchProject(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.id
            it.state = p.id == store.project.id ? .on : .off
            projMenu.addItem(it)
        }
        projMenu.addItem(.separator())
        let np = NSMenuItem(title: "New Project…", action: #selector(newProject), keyEquivalent: "")
        np.target = self
        projMenu.addItem(np)
        let lf = NSMenuItem(title: "Link Shared Folder…", action: #selector(linkSharedFolder), keyEquivalent: "")
        lf.target = self
        projMenu.addItem(lf)
        projItem.submenu = projMenu
        menu.addItem(projItem)

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

    @objc private func quickAdd() { QuickAddController.shared.handleHotkey() }

    @objc private func switchProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let p = Projects.all.first(where: { $0.id == id }) else { return }
        RefStore.shared.switchTo(p)
    }

    @objc func newProject() { ProjectActions.newProject() }
    @objc func linkSharedFolder() { ProjectActions.linkSharedFolder() }
    @objc private func toggleEnabled() { Settings.enabled.toggle() }
    @objc private func toggleLabel() { Settings.labelImages.toggle() }
    @objc private func showFolder() { NSWorkspace.shared.open(RefStore.shared.dir) }
    @objc private func setAutoDelete(_ sender: NSMenuItem) {
        Settings.autoDeleteDays = sender.tag
        RefStore.shared.cleanUpUnused()
    }

    @objc func clearAll() {
        let alert = NSAlert()
        let p = RefStore.shared.project
        alert.messageText = "Delete all characters in \(p.name)?"
        alert.informativeText = p.shared
            ? "This is a shared folder: the faces will be deleted for everyone using it (\(RefStore.shared.storageText))."
            : "This removes every tag and its images (\(RefStore.shared.storageText))."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { RefStore.shared.clearAll() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openPermissions() {
        Installer.requestAccessibility(openSettings: true)
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

/// Small dialogs used by the menu bar and the library window.
enum ProjectActions {
    static func ask(_ title: String, _ message: String, initial: String = "", button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static func newProject() {
        guard let name = ask("New Project", "Name it after your video, e.g. Monsoon Run.", button: "Create"),
              let p = Projects.create(name: name) else { return }
        RefStore.shared.switchTo(p)
    }

    /// Pick a folder inside Google Drive / Dropbox / iCloud that you shared with someone.
    static func linkSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Link Folder"
        panel.message = "Choose a folder in Google Drive, Dropbox or iCloud Drive that you share with your team. Everyone who links the same folder uses the same faces."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RefStore.shared.switchTo(Projects.link(folder: url))
    }

    static func renameProject() {
        let p = RefStore.shared.project
        guard let name = ask("Rename Project", "", initial: p.name, button: "Rename") else { return }
        Projects.rename(p, to: name)
        RefStore.shared.refreshProject()
    }

    static func removeProject() {
        let p = RefStore.shared.project
        guard Projects.all.count > 1 else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = p.shared ? "Unlink \(p.name)?" : "Delete \(p.name)?"
        alert.informativeText = p.shared
            ? "The shared folder and everyone's faces stay as they are. RefTags just stops using it."
            : "This deletes the project and all its faces from this Mac."
        alert.addButton(withTitle: p.shared ? "Unlink" : "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Projects.remove(p)
        RefStore.shared.switchTo(Projects.active)
    }
}

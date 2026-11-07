import AppKit

/// Shortcuts. Change the key codes here if you ever want different keys.
/// (key codes: V = 9, R = 15, B = 11, G = 5)
enum Hotkeys {
    /// Accept the popup and paste the reference images.  ⌃⌘V
    static let acceptKeyCode: Int64 = 9
    static let acceptLabel = "⌃⌘V"
    /// Save the image on the clipboard under a new tag.  ⌃⌘R
    static let quickAddKeyCode: Int64 = 15
    static let quickAddLabel = "⌃⌘R"
}

/// Watches the keyboard system-wide (needs Accessibility permission) to spot tags
/// as you type them and prompts as you paste them.
final class KeyMonitor {
    let store: RefStore
    var onQuickAdd: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private var pendingPaste: DispatchWorkItem?
    private(set) var running = false
    private let myPid = ProcessInfo.processInfo.processIdentifier

    init(store: RefStore) { self.store = store }

    @discardableResult
    func start() -> Bool {
        if running { return true }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        running = true
        return true
    }

    // Runs for every key press / click. Keep it fast; UI work is dispatched async.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Paster.marker { return pass }

        let popup = PopupController.shared

        if type == .leftMouseDown || type == .rightMouseDown {
            buffer = ""
            if popup.isVisible && !popup.containsMouse() {
                DispatchQueue.main.async { popup.hide() }
            }
            return pass
        }
        guard type == .keyDown else { return pass }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let ctrl = flags.contains(.maskControl)
        let opt = flags.contains(.maskAlternate)
        let shift = flags.contains(.maskShift)
        let ctrlCmdOnly = cmd && ctrl && !opt && !shift

        // ⌃⌘R — quick add, works everywhere
        if ctrlCmdOnly && keyCode == Hotkeys.quickAddKeyCode {
            DispatchQueue.main.async { self.onQuickAdd?() }
            return nil
        }

        guard Settings.enabled else { return pass }

        // ⌃⌘V — accept the popup (only grabbed while the popup is showing)
        if ctrlCmdOnly && keyCode == Hotkeys.acceptKeyCode && popup.isVisible {
            buffer = ""
            DispatchQueue.main.async { popup.accept() }
            return nil
        }

        // Don't react to typing inside RefTags itself (e.g. naming a tag).
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == myPid { return pass }

        // Normal ⌘V — check the pasted text for tags.
        if cmd && !ctrl && !opt && keyCode == 9 {
            buffer = ""
            checkPaste()
            return pass
        }
        if cmd || ctrl {
            buffer = ""
            if popup.isVisible && popup.kind == .typed { DispatchQueue.main.async { popup.hide() } }
            return pass
        }

        switch keyCode {
        case 53, 36, 76: // esc, return, enter → close the popup, key still goes to the app
            buffer = ""
            if popup.isVisible { DispatchQueue.main.async { popup.hide() } }
            return pass
        case 51: // backspace
            if !buffer.isEmpty { buffer.removeLast() }
            checkTyped()
            return pass
        case 48, 117, 115, 116, 119, 121, 123, 124, 125, 126: // tab, fwd-delete, home, pgup, end, pgdn, arrows
            buffer = ""
            hideTypedPopup()
            return pass
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        if length > 0 {
            buffer += String(utf16CodeUnits: chars, count: length)
            if buffer.count > 80 { buffer = String(buffer.suffix(80)) }
        }
        checkTyped()
        return pass
    }

    /// The word you're in the middle of typing.
    private func trailingToken() -> String {
        var token = ""
        for ch in buffer.reversed() {
            if ch.isLetter || ch.isNumber || ch == "_" { token.insert(ch, at: token.startIndex) } else { break }
        }
        return token
    }

    private func checkTyped() {
        let token = trailingToken()
        let popup = PopupController.shared

        if let entry = store.entry(forToken: token) {
            let full = Settings.prefix + entry.tag
            if popup.isVisible && popup.kind == .typed && popup.currentKey == full { return }
            let images = store.images(for: entry)
            let n = images.count
            DispatchQueue.main.async {
                popup.show(kind: .typed, key: full,
                           title: "Include \(full)?",
                           subtitle: n == 1 ? "1 reference image" : "\(n) reference images",
                           images: images) {
                    Paster.paste(entries: [entry])
                }
            }
            return
        }
        // Typing a space/comma right after the tag keeps the popup up for a moment;
        // starting a new word closes it.
        if popup.isVisible && popup.kind == .typed && !token.isEmpty {
            DispatchQueue.main.async { popup.hide() }
        }
    }

    private func hideTypedPopup() {
        let popup = PopupController.shared
        if popup.isVisible && popup.kind == .typed { DispatchQueue.main.async { popup.hide() } }
    }

    private func checkPaste() {
        pendingPaste?.cancel()
        guard !Paster.isPasting,
              let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let found = store.tagsMentioned(in: text)
        guard !found.isEmpty else { return }

        let store = self.store
        let work = DispatchWorkItem {
            let names = found.map { Settings.prefix + $0.tag }.joined(separator: " · ")
            let thumbs = found.compactMap { store.thumbnail(for: $0) }
            let title = found.count == 1
                ? "Paste reference for \(Settings.prefix + found[0].tag)?"
                : "Paste all \(found.count) \(Settings.prefix)-tags?"
            PopupController.shared.show(kind: .pasted, key: "paste:" + names,
                                        title: title, subtitle: names, images: thumbs) {
                Paster.paste(entries: found)
            }
        }
        pendingPaste = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

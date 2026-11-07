import AppKit

/// Pastes reference images into whatever app is focused (ChatGPT in the browser, etc.)
/// by putting each image on the clipboard and sending ⌘V. Your original clipboard
/// (e.g. the prompt text) is put back afterwards.
enum Paster {
    /// Marks our own synthetic key events so the key monitor ignores them.
    static let marker: Int64 = 0x5245_4654 // "REFT"
    private(set) static var isPasting = false

    static func paste(entries: [RefEntry]) {
        let store = RefStore.shared
        store.markUsed(entries.map { $0.tag })
        var items: [(NSImage, String)] = []
        for e in entries {
            for img in store.images(for: e) { items.append((img, Settings.prefix + e.tag)) }
        }
        paste(items)
    }

    static func paste(_ images: [(NSImage, String)]) {
        guard !images.isEmpty, !isPasting else { return }
        isPasting = true
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let label = Settings.labelImages
        // Prepare all PNG data up front so the pastes fire quickly one after another.
        let payloads: [Data] = images.compactMap { img, tag in
            (label ? img.labeled(tag) : img).pngData()
        }
        var queue = payloads

        func step() {
            guard !queue.isEmpty else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    restore(saved, pb)
                    isPasting = false
                }
                return
            }
            let data = queue.removeFirst()
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            pb.writeObjects([item])
            sendCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { step() }
        }
        // small delay so the Return key that accepted the popup is fully released
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { step() }
    }

    static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else { return }
        for e in [down, up] {
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types {
                if let d = item.data(forType: t) { copy.setData(d, forType: t) }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], _ pb: NSPasteboard) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

import AppKit
import Combine
import UniformTypeIdentifiers

struct RefEntry: Codable, Identifiable, Equatable {
    var tag: String        // stored without the prefix, lowercase: "bharat"
    var files: [String]    // image file names inside the store folder
    var lastUsed: Date?    // last time it was saved, added to or pasted
    var id: String { tag }
}

/// Saves reference images in ~/Library/Application Support/RefTags
final class RefStore: ObservableObject {
    static let shared = RefStore()

    @Published private(set) var entries: [RefEntry] = []
    let dir: URL
    private var cache: [String: NSImage] = [:]
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("RefTags", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([RefEntry].self, from: data) else { return }
        entries = list.filter { !$0.files.isEmpty }
        // older saves have no date yet: start their clock now
        var changed = false
        for i in entries.indices where entries[i].lastUsed == nil {
            entries[i].lastUsed = Date(); changed = true
        }
        if changed { save() }
    }

    // MARK: keeping storage small

    /// Deletes tags not used for `Settings.autoDeleteDays` days (0 = never).
    func cleanUpUnused() {
        let days = Settings.autoDeleteDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = entries.filter { ($0.lastUsed ?? Date()) < cutoff }
        guard !old.isEmpty else { return }
        for e in old { for f in e.files { deleteFile(f) } }
        entries.removeAll { e in old.contains { $0.tag == e.tag } }
        save()
    }

    func markUsed(_ tags: [String]) {
        var changed = false
        for i in entries.indices where tags.contains(entries[i].tag) {
            entries[i].lastUsed = Date(); changed = true
        }
        if changed { save() }
    }

    func clearAll() {
        for e in entries { for f in e.files { deleteFile(f) } }
        entries.removeAll()
        save()
    }

    /// Total size of saved images, e.g. "4.2 MB".
    var storageText: String {
        var bytes: Int64 = 0
        for e in entries {
            for f in e.files {
                let url = dir.appendingPathComponent(f)
                if let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
                    bytes += n.int64Value
                }
            }
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func save() {
        entries.sort { $0.tag < $1.tag }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: tags

    /// "Bharat Kumar!" → "bharatkumar"
    static func clean(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var out = ""
        for s in raw.lowercased().unicodeScalars where allowed.contains(s) {
            out.unicodeScalars.append(s)
        }
        return out
    }

    func entry(named tag: String) -> RefEntry? {
        entries.first { $0.tag == tag }
    }

    /// "rbharat" → entry "bharat" (if it exists)
    func entry(forToken token: String) -> RefEntry? {
        let t = token.lowercased()
        let p = Settings.prefix
        guard t.count > p.count, t.hasPrefix(p) else { return nil }
        return entry(named: String(t.dropFirst(p.count)))
    }

    /// Every saved tag mentioned in a block of text, in order of first appearance.
    func tagsMentioned(in text: String) -> [RefEntry] {
        var seen = Set<String>()
        var out: [RefEntry] = []
        var word = ""
        func flush() {
            if let e = entry(forToken: word), !seen.contains(e.tag) {
                seen.insert(e.tag)
                out.append(e)
            }
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" { word.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    // MARK: editing

    @discardableResult
    func add(images: [NSImage], tag raw: String) -> Bool {
        let tag = RefStore.clean(raw)
        guard !tag.isEmpty, !images.isEmpty else { return false }
        var newFiles: [String] = []
        for img in images {
            // compressed JPEG, max 1536px: ~200–400 KB instead of several MB
            guard let jpg = img.downscaled(maxSide: 1536).jpegData(quality: 0.85) else { continue }
            let name = "\(tag)-\(UUID().uuidString.prefix(8)).jpg"
            do {
                try jpg.write(to: dir.appendingPathComponent(name), options: .atomic)
                newFiles.append(name)
            } catch { continue }
        }
        guard !newFiles.isEmpty else { return false }
        if let i = entries.firstIndex(where: { $0.tag == tag }) {
            entries[i].files.append(contentsOf: newFiles)
            entries[i].lastUsed = Date()
        } else {
            entries.append(RefEntry(tag: tag, files: newFiles, lastUsed: Date()))
        }
        save()
        return true
    }

    func remove(tag: String) {
        guard let e = entry(named: tag) else { return }
        for f in e.files { deleteFile(f) }
        entries.removeAll { $0.tag == tag }
        save()
    }

    func removeImage(tag: String, file: String) {
        guard let i = entries.firstIndex(where: { $0.tag == tag }) else { return }
        entries[i].files.removeAll { $0 == file }
        deleteFile(file)
        if entries[i].files.isEmpty { entries.remove(at: i) }
        save()
    }

    @discardableResult
    func rename(tag: String, to raw: String) -> Bool {
        let newTag = RefStore.clean(raw)
        guard !newTag.isEmpty, newTag != tag,
              let i = entries.firstIndex(where: { $0.tag == tag }) else { return false }
        if let j = entries.firstIndex(where: { $0.tag == newTag }) {
            // merge into the existing tag
            entries[j].files.append(contentsOf: entries[i].files)
            entries.remove(at: i)
        } else {
            entries[i].tag = newTag
        }
        save()
        return true
    }

    private func deleteFile(_ f: String) {
        cache[f] = nil
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
    }

    // MARK: images

    func image(_ file: String) -> NSImage? {
        if let c = cache[file] { return c }
        let img = NSImage(contentsOf: dir.appendingPathComponent(file))
        cache[file] = img
        return img
    }

    func images(for entry: RefEntry) -> [NSImage] {
        entry.files.compactMap { image($0) }
    }

    func thumbnail(for entry: RefEntry) -> NSImage? {
        entry.files.first.flatMap { image($0) }
    }

    /// Images currently on the clipboard: copied images, or image files copied in Finder.
    static func imagesFromPasteboard(_ pb: NSPasteboard = .general) -> [NSImage] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            let imgs = urls.compactMap { NSImage(contentsOf: $0) }
            if !imgs.isEmpty { return imgs }
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !imgs.isEmpty {
            return imgs
        }
        return []
    }
}

// MARK: - NSImage helpers

extension NSImage {
    var pixelSize: CGSize {
        if let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cg.width, height: cg.height)
        }
        return size
    }

    func pngData() -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    func jpegData(quality: Double) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Draws into a fresh bitmap of exact pixel size (avoids Retina doubling).
    private static func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> NSImage? {
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        draw(ctx.cgContext)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: width, height: height))
        out.addRepresentation(rep)
        return out
    }

    func downscaled(maxSide: CGFloat) -> NSImage {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        if scale >= 1 { return self }
        let nw = Int(w * scale), nh = Int(h * scale)
        return NSImage.render(width: nw, height: nh) { c in
            c.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        } ?? self
    }

    /// Adds a black strip with `text` under the image.
    func labeled(_ text: String) -> NSImage {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let w = cg.width, h = cg.height
        let bar = max(36, Int(Double(h) * 0.07))
        return NSImage.render(width: w, height: h + bar) { c in
            c.setFillColor(NSColor.black.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: bar))
            c.draw(cg, in: CGRect(x: 0, y: bar, width: w, height: h))
            let font = NSFont.boldSystemFont(ofSize: CGFloat(bar) * 0.6)
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: NSPoint(x: (CGFloat(w) - sz.width) / 2, y: (CGFloat(bar) - sz.height) / 2))
        } ?? self
    }
}

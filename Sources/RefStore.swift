import AppKit
import Combine
import UniformTypeIdentifiers

struct RefEntry: Identifiable, Equatable {
    var tag: String        // without the prefix, lowercase: "bharat"
    var files: [String]    // image file names inside the project folder
    var id: String { tag }
}

/// The faces of the active project. The folder itself is the source of truth:
/// every image file "<tag>-<anything>.jpg" belongs to that tag. That way a project
/// inside a shared Google Drive / Dropbox / iCloud folder syncs between people for free.
final class RefStore: ObservableObject {
    static let shared = RefStore()

    @Published private(set) var entries: [RefEntry] = []
    @Published private(set) var project: Project
    var dir: URL { project.url }

    private var cache: [String: NSImage] = [:]
    private var lastSignature = ""
    private var watchTimer: Timer?
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "gif", "bmp"]

    private init() {
        project = Projects.active
        migrateLegacyIndex()
        reload(force: true)
        // pick up faces added by collaborators (or dropped into the folder in Finder)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    // MARK: projects

    func switchTo(_ p: Project) {
        Projects.setActive(p)
        project = p
        cache.removeAll()
        lastSignature = ""
        reload(force: true)
    }

    /// Re-read the active project's name etc. after a rename / removal.
    func refreshProject() {
        let p = Projects.active
        if p != project { switchTo(p) }
    }

    // MARK: scanning

    static func tag(fromFileName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let base = stem.split(separator: "-", maxSplits: 1).first.map(String.init) ?? stem
        return clean(base)
    }

    /// All tags in a folder, files oldest first.
    static func scan(_ folder: URL) -> [RefEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var byTag: [String: [(String, Date)]] = [:]
        for u in urls where imageExtensions.contains(u.pathExtension.lowercased()) {
            let name = u.lastPathComponent
            let t = RefStore.tag(fromFileName: name)
            guard !t.isEmpty else { continue }
            let date = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            byTag[t, default: []].append((name, date))
        }
        return byTag.map { tag, files in
            RefEntry(tag: tag, files: files.sorted { $0.1 < $1.1 }.map { $0.0 })
        }.sorted { $0.tag < $1.tag }
    }

    func reload(force: Bool = false) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let found = RefStore.scan(dir)
        let sig = found.map { $0.tag + ":" + $0.files.joined(separator: ",") }.joined(separator: "|")
        if !force && sig == lastSignature { return }
        lastSignature = sig
        entries = found
        for e in found where lastUsed(project.id, e.tag) == nil { setLastUsed(project.id, e.tag) }
    }

    /// v1 kept an index.json and renamed tags only inside it. Rename the files to match, then drop it.
    private func migrateLegacyIndex() {
        let index = Projects.baseDir.appendingPathComponent("index.json")
        struct Old: Codable { var tag: String; var files: [String] }
        guard let data = try? Data(contentsOf: index),
              let list = try? JSONDecoder().decode([Old].self, from: data) else { return }
        let fm = FileManager.default
        for e in list {
            for f in e.files where RefStore.tag(fromFileName: f) != e.tag {
                let ext = (f as NSString).pathExtension
                let to = "\(e.tag)-\(UUID().uuidString.prefix(8)).\(ext)"
                try? fm.moveItem(at: Projects.baseDir.appendingPathComponent(f),
                                 to: Projects.baseDir.appendingPathComponent(to))
            }
        }
        try? fm.removeItem(at: index)
    }

    // MARK: last used (kept locally, never written into shared folders)

    private func usedKey(_ projectID: String, _ tag: String) -> String { "used|\(projectID)|\(tag)" }

    private func lastUsed(_ projectID: String, _ tag: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: usedKey(projectID, tag))
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func setLastUsed(_ projectID: String, _ tag: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: usedKey(projectID, tag))
    }

    func markUsed(_ tags: [String]) {
        for t in tags { setLastUsed(project.id, t) }
    }

    // MARK: keeping storage small

    /// Deletes tags not used for `Settings.autoDeleteDays` days, in your own projects only
    /// (never in shared folders, where other people's faces live).
    func cleanUpUnused() {
        let days = Settings.autoDeleteDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        for p in Projects.all where !p.shared {
            for e in RefStore.scan(p.url) {
                guard let last = lastUsed(p.id, e.tag) else { setLastUsed(p.id, e.tag); continue }
                if last < cutoff {
                    for f in e.files { try? fm.removeItem(at: p.url.appendingPathComponent(f)) }
                }
            }
        }
        cache.removeAll()
        reload(force: true)
    }

    func clearAll() {
        for e in entries { for f in e.files { deleteFile(f) } }
        reload(force: true)
    }

    /// Total size of this project's images, e.g. "4.2 MB".
    var storageText: String {
        var bytes: Int64 = 0
        for e in entries {
            for f in e.files {
                let path = dir.appendingPathComponent(f).path
                if let n = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                    bytes += n.int64Value
                }
            }
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

    /// Autocomplete: "rsh" → [sherlock, shiva …]. Needs the prefix + at least 2 letters.
    /// Exact match first, then tags starting with what you typed, then tags containing it.
    func suggestions(forToken token: String, limit: Int = 6) -> [RefEntry] {
        let t = token.lowercased()
        let p = Settings.prefix
        guard t.hasPrefix(p) else { return [] }
        let typed = String(t.dropFirst(p.count))
        guard typed.count >= 2 else { return [] }
        let exact = entries.filter { $0.tag == typed }
        let starts = entries.filter { $0.tag != typed && $0.tag.hasPrefix(typed) }
        let contains = typed.count >= 3
            ? entries.filter { !$0.tag.hasPrefix(typed) && $0.tag.contains(typed) } : []
        return Array((exact + starts + contains).prefix(limit))
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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var saved = false
        for img in images {
            // compressed JPEG, max 1536px: ~200–400 KB instead of several MB
            guard let jpg = img.downscaled(maxSide: 1536).jpegData(quality: 0.85) else { continue }
            let name = "\(tag)-\(UUID().uuidString.prefix(8)).jpg"
            if (try? jpg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil { saved = true }
        }
        guard saved else { return false }
        setLastUsed(project.id, tag)
        reload(force: true)
        return true
    }

    func remove(tag: String) {
        guard let e = entry(named: tag) else { return }
        for f in e.files { deleteFile(f) }
        reload(force: true)
    }

    func removeImage(tag: String, file: String) {
        deleteFile(file)
        reload(force: true)
    }

    @discardableResult
    func rename(tag: String, to raw: String) -> Bool {
        let newTag = RefStore.clean(raw)
        guard !newTag.isEmpty, newTag != tag, let e = entry(named: tag) else { return false }
        let fm = FileManager.default
        for f in e.files {
            let ext = (f as NSString).pathExtension
            let to = "\(newTag)-\(UUID().uuidString.prefix(8)).\(ext)"
            try? fm.moveItem(at: dir.appendingPathComponent(f), to: dir.appendingPathComponent(to))
            cache[f] = nil
        }
        setLastUsed(project.id, newTag)
        reload(force: true)
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

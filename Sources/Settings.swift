import Foundation

/// Tiny wrapper around UserDefaults. Keys are shared with @AppStorage in the SwiftUI views.
enum Settings {
    static let enabledKey = "enabled"
    static let labelKey = "labelImages"
    static let prefixKey = "prefix"
    static let autoDeleteKey = "autoDeleteDays"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Adds a black strip with the tag name under each pasted image,
    /// so ChatGPT knows which reference is which character.
    static var labelImages: Bool {
        get { UserDefaults.standard.object(forKey: labelKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: labelKey) }
    }

    /// The letter(s) in front of every tag. "r" → rbharat, rmeera …
    static var prefix: String {
        let p = (UserDefaults.standard.string(forKey: prefixKey) ?? "r").lowercased()
        return p.isEmpty ? "r" : p
    }

    /// Tags not used for this many days are deleted (own projects only). 0 = keep forever.
    static var autoDeleteDays: Int {
        get { UserDefaults.standard.object(forKey: autoDeleteKey) as? Int ?? 14 }
        set { UserDefaults.standard.set(newValue, forKey: autoDeleteKey) }
    }
}

/// A project = one folder of face images. A shared project is a folder you linked
/// (e.g. inside Google Drive / Dropbox / iCloud) so collaborators see the same tags.
struct Project: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var path: String
    var shared: Bool

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

enum Projects {
    private static let listKey = "projects"
    private static let activeKey = "activeProject"

    static var baseDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RefTags", isDirectory: true)
    }

    static var all: [Project] {
        get {
            if let data = UserDefaults.standard.data(forKey: listKey),
               let list = try? JSONDecoder().decode([Project].self, from: data), !list.isEmpty {
                return list
            }
            // First run: the original folder becomes "My Characters"
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            return [Project(id: "default", name: "My Characters", path: baseDir.path, shared: false)]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: listKey)
            }
        }
    }

    static var active: Project {
        let list = all
        let id = UserDefaults.standard.string(forKey: activeKey)
        return list.first { $0.id == id } ?? list[0]
    }

    static func setActive(_ p: Project) {
        UserDefaults.standard.set(p.id, forKey: activeKey)
    }

    @discardableResult
    static func create(name raw: String) -> Project? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let parent = baseDir.appendingPathComponent("Projects", isDirectory: true)
        var dir = parent.appendingPathComponent(safe, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = parent.appendingPathComponent("\(safe) \(n)", isDirectory: true)
            n += 1
        }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        let p = Project(id: UUID().uuidString, name: name, path: dir.path, shared: false)
        all = all + [p]
        return p
    }

    /// Use an existing folder (e.g. a shared Google Drive folder) as a project.
    @discardableResult
    static func link(folder: URL) -> Project {
        if let existing = all.first(where: { $0.path == folder.path }) { return existing }
        let p = Project(id: UUID().uuidString, name: folder.lastPathComponent, path: folder.path, shared: true)
        all = all + [p]
        return p
    }

    static func rename(_ p: Project, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        all = all.map { $0.id == p.id ? Project(id: $0.id, name: name, path: $0.path, shared: $0.shared) : $0 }
    }

    /// Removes the project from RefTags. Own projects' images are deleted;
    /// shared folders are only unlinked (other people's files stay untouched).
    static func remove(_ p: Project) {
        var list = all
        guard list.count > 1 else { return }
        let wasActive = active.id == p.id
        list.removeAll { $0.id == p.id }
        all = list
        if !p.shared && p.id != "default" {
            try? FileManager.default.removeItem(at: p.url)
        }
        if wasActive { setActive(list[0]) }
    }
}

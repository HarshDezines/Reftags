import Foundation

/// Tiny wrapper around UserDefaults. Keys are shared with @AppStorage in the SwiftUI views.
enum Settings {
    static let enabledKey = "enabled"
    static let labelKey = "labelImages"
    static let prefixKey = "prefix"
    static let autoDeleteKey = "autoDeleteDays"

    /// Tags not used for this many days are deleted. 0 = keep forever.
    static var autoDeleteDays: Int {
        get { UserDefaults.standard.object(forKey: autoDeleteKey) as? Int ?? 14 }
        set { UserDefaults.standard.set(newValue, forKey: autoDeleteKey) }
    }

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
}

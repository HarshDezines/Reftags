import AppKit

/// First-launch housekeeping so permissions actually stick:
///  • RefTags must run from /Applications (apps opened straight from Downloads run from a
///    hidden temporary copy, and macOS never matches the permission to them).
///  • Stale Accessibility entries from older builds are cleared before asking again.
enum Installer {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.harsh.reftags"

    /// Returns true if the app is relaunching from /Applications (caller should stop).
    static func moveToApplicationsIfNeeded() -> Bool {
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath()
        if here.path.hasPrefix("/Applications/") { return false }
        // Local development build (./build.sh puts it in build/) — leave it alone.
        if here.path.contains("/build/") && !here.path.contains("/AppTranslocation/") { return false }

        let alert = NSAlert()
        alert.messageText = "Move RefTags to your Applications folder?"
        alert.informativeText = "RefTags needs to live in Applications so macOS remembers its permissions. It will reopen from there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let dest = URL(fileURLWithPath: "/Applications/RefTags.app")
        let fm = FileManager.default
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where other.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            other.terminate()
        }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: here, to: dest)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Couldn't move RefTags"
            fail.informativeText = "Please quit RefTags and drag it into your Applications folder yourself.\n\n\(error.localizedDescription)"
            fail.runModal()
            return false
        }
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        // Remove the copy in Downloads (not possible when macOS ran it from a hidden temp location).
        if !here.path.contains("/AppTranslocation/") {
            try? fm.trashItem(at: here, resultingItemURL: nil)
        }
        resetAccessibility()
        // Reopen from Applications once this copy has quit.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", dest.path]
        try? p.run()
        NSApp.terminate(nil)
        return true
    }

    /// Removes old/stale Accessibility entries for RefTags so the next request adds the current app.
    static func resetAccessibility() {
        run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID])
    }

    /// Clears stale entries, shows macOS's permission prompt and opens the right Settings page.
    static func requestAccessibility(openSettings: Bool) {
        resetAccessibility()
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if openSettings {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}

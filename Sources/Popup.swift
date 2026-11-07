import AppKit
import SwiftUI

/// The little floating "Include rbharat?  ⌃⌘V" bubble. It never takes focus
/// away from the app you're typing in.
final class PopupController {
    static let shared = PopupController()

    enum Kind { case typed, pasted }

    private var panel: NSPanel?
    private var onAccept: (() -> Void)?
    private var hideWork: DispatchWorkItem?
    private(set) var isVisible = false
    private(set) var kind: Kind = .typed
    private(set) var currentKey = ""

    func show(kind: Kind, key: String, title: String, subtitle: String, images: [NSImage],
              onAccept: @escaping () -> Void) {
        self.kind = kind
        self.currentKey = key
        self.onAccept = onAccept

        let view = PopupView(title: title, subtitle: subtitle, images: images,
                             shortcut: Hotkeys.acceptLabel,
                             onTap: { [weak self] in self?.accept() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize

        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        let origin = position(for: size)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.orderFrontRegardless()
        isVisible = true

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .typed ? 5 : 8), execute: work)
    }

    func accept() {
        let action = onAccept
        hide()
        action?()
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        isVisible = false
        onAccept = nil
        currentKey = ""
    }

    func containsMouse() -> Bool {
        guard let p = panel, isVisible else { return false }
        return p.frame.contains(NSEvent.mouseLocation)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }

    /// Just under the text cursor if we can find it, otherwise next to the mouse.
    private func position(for size: NSSize) -> NSPoint {
        var pt: NSPoint
        if let caret = Caret.rect() {
            pt = NSPoint(x: caret.minX, y: caret.minY - size.height - 6)
        } else {
            let m = NSEvent.mouseLocation
            pt = NSPoint(x: m.x + 12, y: m.y - size.height - 12)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(pt) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            pt.x = min(max(pt.x, vf.minX + 4), vf.maxX - size.width - 4)
            pt.y = min(max(pt.y, vf.minY + 4), vf.maxY - size.height - 4)
        }
        return pt
    }
}

struct PopupView: View {
    let title: String
    let subtitle: String
    let images: [NSImage]
    let shortcut: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: -10) {
                ForEach(0..<min(images.count, 5), id: \.self) { i in
                    Image(nsImage: images[i])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(shortcut)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.85)))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minWidth: 240, maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .fixedSize()
    }
}

/// Finds the text cursor position in the focused app via Accessibility.
enum Caret {
    private static var enabledPids = Set<pid_t>()

    static func rect() -> NSRect? {
        enableBrowserAccessibility()
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let el = focused as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let range = rangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &boundsRef) == .success,
              let b = boundsRef, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &r), r.height > 0 else { return nil }

        // AX uses top-left origin; Cocoa uses bottom-left of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height,
                      width: max(r.width, 1), height: r.height)
    }

    /// Chrome / Electron apps only expose caret info when asked to.
    private static func enableBrowserAccessibility() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard !enabledPids.contains(pid) else { return }
        enabledPids.insert(pid)
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

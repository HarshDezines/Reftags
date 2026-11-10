import AppKit
import SwiftUI

/// What the floating bubble shows. Either a single question ("Include rsherlock?")
/// or a list of autocomplete suggestions you can move through with ↑ ↓.
final class PopupModel: ObservableObject {
    struct Row: Identifiable {
        let id: String       // tag
        let label: String    // "rsherlock"
        let typed: Int       // how many leading characters match what you typed
        let thumb: NSImage?
        let count: Int
    }
    @Published var title = ""
    @Published var subtitle = ""
    @Published var images: [NSImage] = []
    @Published var rows: [Row] = []
    @Published var selected = 0
}

final class PopupController {
    static let shared = PopupController()

    enum Kind { case typed, pasted }

    let model = PopupModel()
    private var panel: NSPanel?
    private var host: NSHostingView<PopupView>?
    private var onAcceptSingle: (() -> Void)?
    private var onAcceptRow: ((Int) -> Void)?
    private var hideWork: DispatchWorkItem?
    private(set) var isVisible = false
    private(set) var kind: Kind = .typed
    private(set) var currentKey = ""

    /// More than one suggestion → ↑ ↓ choose between them.
    var isList: Bool { isVisible && model.rows.count > 1 }

    func showSingle(kind: Kind, key: String, title: String, subtitle: String, images: [NSImage],
                    onAccept: @escaping () -> Void) {
        model.rows = []
        model.title = title
        model.subtitle = subtitle
        model.images = images
        model.selected = 0
        onAcceptSingle = onAccept
        onAcceptRow = nil
        present(kind: kind, key: key)
    }

    func showList(key: String, rows: [PopupModel.Row], onAccept: @escaping (Int) -> Void) {
        let keepSelection = currentKey.hasPrefix("typed:") && isVisible
        let previous = keepSelection && model.selected < model.rows.count ? model.rows[model.selected].id : nil
        model.rows = rows
        model.images = []
        model.selected = previous.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        onAcceptRow = onAccept
        onAcceptSingle = nil
        present(kind: .typed, key: key)
    }

    func moveSelection(_ delta: Int) {
        guard !model.rows.isEmpty else { return }
        model.selected = (model.selected + delta + model.rows.count) % model.rows.count
        restartTimer()
    }

    func accept() {
        let single = onAcceptSingle
        let row = onAcceptRow
        let index = model.selected
        hide()
        if let row { row(index) } else { single?() }
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        isVisible = false
        onAcceptSingle = nil
        onAcceptRow = nil
        currentKey = ""
    }

    func containsMouse() -> Bool {
        guard let p = panel, isVisible else { return false }
        return p.frame.contains(NSEvent.mouseLocation)
    }

    // MARK: window

    private func present(kind: Kind, key: String) {
        self.kind = kind
        let wasVisible = isVisible
        currentKey = key

        let p = panel ?? makePanel()
        panel = p
        if host == nil {
            let h = NSHostingView(rootView: PopupView(model: model, shortcut: Hotkeys.acceptLabel,
                                                      onTap: { [weak self] i in
                                                          self?.model.selected = i
                                                          self?.accept()
                                                      }))
            host = h
            p.contentView = h
        }
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? NSSize(width: 300, height: 60)
        // Keep the bubble where it is while you keep typing; only place it fresh when it appears.
        let origin = wasVisible ? NSPoint(x: p.frame.minX, y: p.frame.maxY - size.height) : position(for: size)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.orderFrontRegardless()
        isVisible = true
        restartTimer()
    }

    private func restartTimer() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .typed ? 6 : 8), execute: work)
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
    @ObservedObject var model: PopupModel
    let shortcut: String
    let onTap: (Int) -> Void

    var body: some View {
        Group {
            if model.rows.isEmpty { single } else { list }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .fixedSize()
    }

    private var keycap: some View {
        Text(shortcut)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.85)))
            .foregroundColor(.white)
    }

    private var single: some View {
        HStack(spacing: 10) {
            HStack(spacing: -10) {
                ForEach(0..<min(model.images.count, 5), id: \.self) { i in
                    thumb(model.images[i], size: 36)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: 13, weight: .semibold))
                Text(model.subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            keycap
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minWidth: 240, maxWidth: 420)
        .contentShape(Rectangle())
        .onTapGesture { onTap(0) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                HStack(spacing: 9) {
                    if let t = row.thumb { thumb(t, size: 28) } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2)).frame(width: 28, height: 28)
                    }
                    (Text(String(row.label.prefix(row.typed))).foregroundColor(.secondary)
                        + Text(String(row.label.dropFirst(row.typed))).fontWeight(.semibold))
                        .font(.system(size: 13, design: .rounded))
                    if row.count > 1 {
                        Text("\(row.count)").font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                    Spacer(minLength: 12)
                    if i == model.selected { keycap }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(i == model.selected ? Color.accentColor.opacity(0.18) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { onTap(i) }
            }
            if model.rows.count > 1 {
                Text("↑ ↓ choose").font(.system(size: 10)).foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.top, 2)
            }
        }
        .padding(6)
        .frame(minWidth: 230, maxWidth: 360, alignment: .leading)
    }

    private func thumb(_ img: NSImage, size: CGFloat) -> some View {
        Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).stroke(Color.white.opacity(0.9), lineWidth: 1.5))
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

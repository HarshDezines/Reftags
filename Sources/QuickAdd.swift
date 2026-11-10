import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// ⌃⌘R:
///  • an image is copied → small box shows it, type a tag, ↩
///  • nothing copied → drag a box around any part of the screen (like ⌘⇧4)
///  • box already open → ⌃⌘R again switches to capturing an area instead
final class QuickAddController {
    static let shared = QuickAddController()
    private var panel: KeyablePanel?
    private var previousApp: NSRunningApplication?
    private var capturing = false

    var isVisible: Bool { panel?.isVisible ?? false }

    func handleHotkey() {
        if capturing { return }
        if isVisible { startCapture(); return }
        rememberFrontApp()
        let images = RefStore.imagesFromPasteboard()
        if images.isEmpty { startCapture() } else { show(images: images, fromClipboard: true) }
    }

    private func rememberFrontApp() {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me {
            previousApp = front
        }
    }

    // MARK: area capture

    func startCapture() {
        capturing = true
        panel?.orderOut(nil)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("reftags-capture-\(UUID().uuidString).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-x", file.path]   // interactive area selection, no sound
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                if let img = NSImage(contentsOf: file) {
                    try? FileManager.default.removeItem(at: file)
                    self.show(images: [img], fromClipboard: false)
                } else {
                    // Esc pressed during capture
                    self.close(restoreFocus: true)
                }
            }
        }
        do { try proc.run() } catch { capturing = false; NSSound.beep() }
    }

    // MARK: box

    func show(images: [NSImage], fromClipboard: Bool) {
        let view = QuickAddView(images: images,
                                fromClipboard: fromClipboard,
                                projectName: RefStore.shared.project.name,
                                onSave: { [weak self] tag in
                                    RefStore.shared.add(images: images, tag: tag)
                                    self?.close(restoreFocus: true)
                                },
                                onCapture: { [weak self] in self?.startCapture() },
                                onCancel: { [weak self] in self?.close(restoreFocus: true) })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize

        let p = panel ?? {
            let p = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            return p
        }()
        panel = p
        p.contentView = host
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + 120,
                              width: size.width, height: size.height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func close(restoreFocus: Bool) {
        panel?.orderOut(nil)
        if restoreFocus { previousApp?.activate(options: [.activateIgnoringOtherApps]) }
        previousApp = nil
    }
}

struct QuickAddView: View {
    let images: [NSImage]
    let fromClipboard: Bool
    let projectName: String
    let onSave: (String) -> Void
    let onCapture: () -> Void
    let onCancel: () -> Void

    @State private var tag = ""
    @FocusState private var focused: Bool
    @ObservedObject private var store = RefStore.shared

    private var cleaned: String { RefStore.clean(tag) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(0..<min(images.count, 4), id: \.self) { i in
                    Image(nsImage: images[i]).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: images.count == 1 ? 140 : 80, height: images.count == 1 ? 140 : 80)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            HStack(spacing: 2) {
                Text(Settings.prefix).font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.accentColor)
                TextField("tag name", text: $tag)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .focused($focused)
                    .onSubmit { if !cleaned.isEmpty { onSave(tag) } }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Group {
                if let e = store.entry(named: cleaned) {
                    Text("Adds to existing \(Settings.prefix + e.tag) (\(e.files.count) image\(e.files.count == 1 ? "" : "s"))")
                } else {
                    Text("↩ save to \(projectName)   ·   esc cancel")
                }
            }
            .font(.caption).foregroundColor(.secondary)

            if fromClipboard {
                Button(action: onCapture) {
                    Label("Capture an area instead  \(Hotkeys.quickAddLabel)", systemImage: "viewfinder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(18)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1)))
        .onExitCommand { onCancel() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
    }
}

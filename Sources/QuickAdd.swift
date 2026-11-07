import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// ⌃⌘R: a small box in the middle of the screen. Shows the copied image,
/// type a tag, press Return. Done.
final class QuickAddController {
    static let shared = QuickAddController()
    private var panel: KeyablePanel?
    private var previousApp: NSRunningApplication?

    func show() {
        let images = RefStore.imagesFromPasteboard()
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me {
            previousApp = front
        }

        let view = QuickAddView(images: images,
                                onSave: { [weak self] tag in
                                    RefStore.shared.add(images: images, tag: tag)
                                    self?.close(restoreFocus: true)
                                },
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
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var tag = ""
    @FocusState private var focused: Bool
    @ObservedObject private var store = RefStore.shared

    private var cleaned: String { RefStore.clean(tag) }

    var body: some View {
        VStack(spacing: 12) {
            if images.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 30)).foregroundColor(.secondary)
                    Text("No image on the clipboard").font(.headline)
                    Text("Copy a face image first (⌘C), then press \(Hotkeys.quickAddLabel).")
                        .font(.caption).foregroundColor(.secondary)
                    Button("OK") { onCancel() }.keyboardShortcut(.defaultAction).padding(.top, 4)
                }
                .padding(8)
            } else {
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
                        Text("↩ save   ·   esc cancel")
                    }
                }
                .font(.caption).foregroundColor(.secondary)
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

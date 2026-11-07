import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var store = RefStore.shared
    @AppStorage(Settings.labelKey) private var labelImages = true
    @AppStorage(Settings.enabledKey) private var enabled = true

    @State private var pending: [NSImage] = []
    @State private var newTag = ""
    @State private var trusted = AXIsProcessTrusted()
    @State private var copiedFlash = false
    @FocusState private var tagFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if !trusted { permissionBanner }
            addBar
            Divider()
            if store.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.entries) { e in EntryCard(entry: e) }
                    }
                    .padding(16)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 460)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            loadDropped(providers); return true
        }
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
        .onAppear { grabClipboardIfImage() }
    }

    // MARK: sections

    private var permissionBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text("RefTags needs Accessibility permission to see tags you type and paste images.")
                .font(.callout)
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var addBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundColor(.secondary.opacity(0.6))
                if pending.isEmpty {
                    VStack(spacing: 2) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 20))
                        Text("⇧⌘V or drop").font(.caption2)
                    }
                    .foregroundColor(.secondary)
                } else {
                    HStack(spacing: -14) {
                        ForEach(0..<min(pending.count, 3), id: \.self) { i in
                            Image(nsImage: pending[i]).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .frame(width: 84, height: 70)
            .onTapGesture { grabClipboard() }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    Text(Settings.prefix).font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.accentColor)
                    TextField("tag name (e.g. bharat)", text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .focused($tagFocused)
                        .onSubmit(save)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                Text(pending.isEmpty
                     ? "Copy a face image, press ⇧⌘V here (or \(Hotkeys.quickAddLabel) from any app)."
                     : "\(pending.count) image\(pending.count == 1 ? "" : "s") ready. Type a tag and press ↩.")
                    .font(.caption).foregroundColor(.secondary)
            }

            VStack(spacing: 6) {
                Button("Paste Image") { grabClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending.isEmpty || RefStore.clean(newTag).isEmpty)
            }
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.crop.square.badge.camera").font(.system(size: 42)).foregroundColor(.secondary)
            Text("No characters yet").font(.title3.bold())
            Text("Add a face above and give it a tag like \(Settings.prefix)bharat.\nThen type \(Settings.prefix)bharat anywhere → press \(Hotkeys.acceptLabel) → the image gets pasted.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Toggle("On", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
            Toggle("Name label under pasted images", isOn: $labelImages).controlSize(.small)
            Spacer()
            Text(store.storageText).foregroundColor(.secondary)
            Button("Clear All") { (NSApp.delegate as? AppDelegate)?.clearAll() }
                .disabled(store.entries.isEmpty)
            Button(copiedFlash ? "Copied ✓" : "Copy tag list for prompt") { copyTagList() }
                .disabled(store.entries.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .font(.callout)
    }

    // MARK: actions

    private func grabClipboard() {
        let imgs = RefStore.imagesFromPasteboard()
        if !imgs.isEmpty { pending = imgs; tagFocused = true } else { NSSound.beep() }
    }

    private func grabClipboardIfImage() {
        let imgs = RefStore.imagesFromPasteboard()
        if !imgs.isEmpty { pending = imgs }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tagFocused = true }
    }

    private func save() {
        guard !pending.isEmpty, !RefStore.clean(newTag).isEmpty else { return }
        if store.add(images: pending, tag: newTag) {
            pending = []
            newTag = ""
        }
    }

    private func copyTagList() {
        let list = store.entries.map { Settings.prefix + $0.tag }.joined(separator: ", ")
        let text = "Characters (reference images attached, each labeled with its tag): \(list)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedFlash = false }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage {
                        DispatchQueue.main.async { pending.append(img); tagFocused = true }
                    }
                }
            } else {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, let img = NSImage(contentsOf: url) {
                        DispatchQueue.main.async { pending.append(img); tagFocused = true }
                    }
                }
            }
        }
    }
}

struct EntryCard: View {
    let entry: RefEntry
    @ObservedObject var store = RefStore.shared
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let img = store.thumbnail(for: entry) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 140).frame(maxWidth: .infinity).clipped()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 140)
                }
                if entry.files.count > 1 {
                    Text("+\(entry.files.count - 1)")
                        .font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.6))).foregroundColor(.white)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Text(Settings.prefix + entry.tag).font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                if hover {
                    Button { copyTag() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy tag")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hover ? 0.07 : 0.04)))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Add clipboard image to \(Settings.prefix + entry.tag)") {
                let imgs = RefStore.imagesFromPasteboard()
                if imgs.isEmpty { NSSound.beep() } else { store.add(images: imgs, tag: entry.tag) }
            }
            Button("Copy tag") { copyTag() }
            Button("Rename…") { rename() }
            if entry.files.count > 1 {
                Menu("Remove one image") {
                    ForEach(Array(entry.files.enumerated()), id: \.offset) { i, f in
                        Button("Image \(i + 1)") { store.removeImage(tag: entry.tag, file: f) }
                    }
                }
            }
            Divider()
            Button("Delete \(Settings.prefix + entry.tag)", role: .destructive) { store.remove(tag: entry.tag) }
        }
    }

    private func copyTag() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Settings.prefix + entry.tag, forType: .string)
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename \(Settings.prefix + entry.tag)"
        alert.informativeText = "New tag name (without the \"\(Settings.prefix)\"):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = entry.tag
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            store.rename(tag: entry.tag, to: field.stringValue)
        }
    }
}

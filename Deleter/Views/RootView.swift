import SwiftUI
import AppKit

/// Root view: directory picker or main browser.
struct RootView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var envModel: AppModel

    var body: some View {
        ZStack {
            if model.rootURL == nil {
                StartScreen(onPick: { envModel.openRoot($0) })
            } else {
                BrowserRoot(model: envModel)
            }
        }
        .onAppear {
            if envModel.rootURL == nil {
                autoPickDirectory()
            }
        }
    }

    private func autoPickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择照片目录"
        panel.message = "选择一个包含照片/视频的目录"
        if panel.runModal() == .OK, let url = panel.url {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                envModel.openRoot(url)
            }
        }
    }
}

/// Landing screen shown before a directory is chosen.
struct StartScreen: View {
    let onPick: (URL) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text("照片筛选器")
                .font(.system(size: 28, weight: .semibold))
            Text("选择一个照片/视频目录开始筛选")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button {
                pick()
            } label: {
                Label("选择目录", systemImage: "folder.badge.plus")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Text("压缩副本将生成在各原片所在目录的 _bside 子文件夹中")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择照片目录"
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }
}

/// Main browser once a directory is open.
struct BrowserRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            Divider()
            BrowserGrid(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .center) {
            QuickLookOverlay(model: model)
                .allowsHitTesting(model.previewIndex != nil)
        }
        .overlay(alignment: .bottom) {
            if let msg = model.lastTrashResult {
                Toast(message: msg) { model.lastTrashResult = nil }
                    .padding(.bottom, 24)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onAppear { NSApplication.shared.keyWindow?.makeFirstResponder(nil) }
        .background(
            KeyHandlerView(model: model)
                .frame(width: 0, height: 0)
        )
    }
}

/// Transparent overlay that captures keyboard events via NSEvent monitor.
struct KeyHandlerView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.model = model
        v.attach()
        return v
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.model = model
    }
}

final class KeyCaptureView: NSView {
    var model: AppModel?
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func attach() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model else { return event }
        // Ignore when a text field has focus.
        if let firstResponder = NSApp.keyWindow?.firstResponder,
           firstResponder is NSTextView || firstResponder is NSTextField {
            return event
        }
        // Ignore OS-generated key repeats for action keys (D, space, arrows,
        // enter) so a held key doesn't fire repeatedly. Held repeats are still
        // allowed to pass through for anything we don't handle here.
        let isActionKey: Bool
        let kc = event.keyCode
        switch kc {
        case 123, 124, 125, 126: isActionKey = true   // arrows
        case 49: isActionKey = true                    // space
        case 36: isActionKey = true                    // return
        default:
            isActionKey = (event.charactersIgnoringModifiers?.lowercased() == "d")
        }
        if event.isARepeat && isActionKey { return nil }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags

        // Space toggles quick-look.
        if key == " " {
            if model.previewIndex != nil {
                model.closePreview()
            } else {
                model.openPreview()
            }
            return nil
        }

        // Escape closes preview.
        if key == .init(UnicodeScalar(0x1b)) {
            if model.previewIndex != nil {
                model.closePreview()
                return nil
            }
        }

        // Arrow navigation.
        if model.previewIndex != nil {
            switch event.keyCode {
            case 123: // left
                model.previewMove(by: -1); return nil
            case 124: // right
                model.previewMove(by: 1); return nil
            case 125, 126: // down/up — also navigate in preview
                model.previewMove(by: event.keyCode == 125 ? 1 : -1); return nil
            default: break
            }
        } else {
            switch event.keyCode {
            case 123: // left
                model.moveSelection(direction: .left); return nil
            case 124: // right
                model.moveSelection(direction: .right); return nil
            case 125: // down
                model.moveSelection(direction: .down); return nil
            case 126: // up
                model.moveSelection(direction: .up); return nil
            default: break
            }
        }

        // D marks / unmarks the CURRENT item only.
        //   - not marked → mark + advance to next
        //   - already marked → unmark, stay put
        if key == "d" && flags.intersection([.command, .control, .option]).isEmpty {
            model.markCurrentAndAdvance(inPreview: model.previewIndex != nil)
            return nil
        }

        // Enter: open selected folder, or preview selected media.
        if key == .init(UnicodeScalar(0x0d)) {
            if model.previewIndex != nil {
                // Already in preview — Enter does nothing extra.
                return nil
            }
            if model.selectedFolderId != nil {
                model.openSelectedFolder()
            } else {
                model.openPreview()
            }
            return nil
        }

        // Backspace goes up one folder.
        // Match by keyCode (51 = Delete/Backspace) rather than the character,
        // because charactersIgnoringModifiers is unreliable for this key under
        // some layouts/IMEs. Also fall back to the U+007F char for safety.
        let isBackspace = kc == 51 || key == "\u{7f}"
        if isBackspace &&
            flags.intersection([.command, .control, .option, .shift]).isEmpty {
            model.goUp()
            return nil
        }

        return event
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A transient toast notification.
struct Toast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().stroke(.quaternary))
            .shadow(radius: 8)
            .task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                onDismiss()
            }
    }
}

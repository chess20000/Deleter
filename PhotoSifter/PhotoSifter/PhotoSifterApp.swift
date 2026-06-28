import SwiftUI
import AppKit

@main
struct PhotoSifterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .environmentObject(model)
                .tint(.theme)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("照片") {
                Button("打开目录…") { pickDirectory() }
                    .keyboardShortcut("o", modifiers: .command)
                // NOTE: D is handled by the local key event monitor in
                // RootView. We intentionally do NOT register a menu shortcut
                // here — doing so fires markCurrentAndAdvance a SECOND time
                // (menu responder + key monitor), which toggles twice per press.
                Button("标记/撤销丢弃 (D)") {
                    model.markCurrentAndAdvance(inPreview: model.previewIndex != nil)
                }
                .disabled(model.selection == nil)
                Divider()
                Button("丢弃原片") { model.discardOriginals() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }

    func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择照片目录"
        panel.message = "选择一个包含照片/视频的目录"
        if panel.runModal() == .OK, let url = panel.url {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                model.openRoot(url)
            }
        }
    }
}

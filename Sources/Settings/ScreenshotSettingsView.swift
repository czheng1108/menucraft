import AppKit
import SwiftUI

struct ScreenshotSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var keyMonitor: Any?
    @State private var keyHint: String?

    var body: some View {
        SettingsSection(title: "快捷键") {
            SettingsRow(title: "打开截图", subtitle: keyHint, symbol: "viewfinder") {
                let shortcut = model.configuration.screenshot.shortcut
                HStack {
                    Button(keyMonitor == nil ? shortcut?.title ?? "设置快捷键…" : "按下组合键…", action: record)
                    if keyMonitor == nil, shortcut != .standard {
                        Button("恢复默认") { model.configuration.screenshot.shortcut = .standard }
                    }
                    if keyMonitor == nil, shortcut != nil {
                        Button("清除") { model.configuration.screenshot.shortcut = nil }
                    }
                }
            }
            if let error = model.screenshotShortcutError {
                Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 11)
            }
        }
        SettingsSection(title: "保存") {
            SettingsRow(title: "截图与录屏保存目录", subtitle: model.configuration.screenshot.saveDirectory ?? "下载（默认）",
                        symbol: "folder") {
                HStack {
                    if model.configuration.screenshot.saveDirectory != nil {
                        Button("恢复为下载") { model.configuration.screenshot.saveDirectory = nil }
                    }
                    Button("选择…") {
                        if let directory = model.chooseDirectory(title: "选择截图保存目录", showSettings: false) {
                            model.configuration.screenshot.saveDirectory = directory.path
                        }
                    }
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func record() {
        stopRecording()
        keyHint = "按下字母或数字与修饰键的组合。Esc 取消。"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            var modifiers: ScreenshotShortcut.Modifiers = []
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            let shortcut = ScreenshotShortcut(keyCode: event.keyCode, key: event.charactersIgnoringModifiers?.uppercased() ?? "",
                                              modifiers: modifiers)
            guard shortcut.isValid else {
                keyHint = "请选择带 Control、Option 或 Command 的字母或数字组合。"
                return nil
            }
            model.configuration.screenshot.shortcut = shortcut
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        keyHint = nil
    }
}

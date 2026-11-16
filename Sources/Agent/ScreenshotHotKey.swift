import Carbon

final class ScreenshotHotKey {
    private let pressed: (ScreenshotShortcutAction) -> Void
    private var registered: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4d435343 // MCSC

    init(pressed: @escaping (ScreenshotShortcutAction) -> Void) { self.pressed = pressed }

    deinit {
        for hotKey in registered { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ shortcuts: [ScreenshotShortcutAction: ScreenshotShortcut]) -> String? {
        for hotKey in registered { UnregisterEventHotKey(hotKey) }
        registered.removeAll()
        guard !shortcuts.isEmpty else { return nil }
        let target = GetApplicationEventTarget()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(target, { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let index = Int(id.id) - 1
                let actions = ScreenshotShortcutAction.allCases
                guard status == noErr, id.signature == ScreenshotHotKey.signature, actions.indices.contains(index) else {
                    return OSStatus(eventNotHandledErr)
                }
                Unmanaged<ScreenshotHotKey>.fromOpaque(context).takeUnretainedValue().pressed(actions[index])
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return "无法监听截图快捷键（\(status)）。可从菜单栏截图。" }
        }
        var failures: [String] = []
        var used = Set<UInt32>()
        for (index, action) in ScreenshotShortcutAction.allCases.enumerated() {
            guard let shortcut = shortcuts[action] else { continue }
            let combo = UInt32(shortcut.keyCode) << 8 | UInt32(shortcut.modifiers.rawValue)
            let status = used.contains(combo) ? OSStatus(eventHotKeyExistsErr) : register(shortcut, id: UInt32(index + 1), target: target)
            if status == noErr { used.insert(combo) }
            else if status == eventHotKeyExistsErr { failures.append("\(action.title)：\(shortcut.title) 已被占用。") }
            else { failures.append("\(action.title)：无法使用 \(shortcut.title)（\(status)）。") }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func register(_ shortcut: ScreenshotShortcut, id: UInt32, target: EventTargetRef?) -> OSStatus {
        var modifiers: UInt32 = 0
        if shortcut.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if shortcut.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        let eventID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, eventID, target, UInt32(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { registered.append(ref) }
        return status
    }
}

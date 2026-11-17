import Carbon

final class ScreenshotHotKey {
    private let pressed: () -> Void
    private var registered: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4d435343 // MCSC

    init(pressed: @escaping () -> Void) { self.pressed = pressed }

    deinit {
        if let registered { UnregisterEventHotKey(registered) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ shortcut: ScreenshotShortcut?) -> String? {
        if let registered { UnregisterEventHotKey(registered) }
        registered = nil
        guard let shortcut else { return nil }
        let target = GetApplicationEventTarget()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(target, { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == ScreenshotHotKey.signature, id.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                Unmanaged<ScreenshotHotKey>.fromOpaque(context).takeUnretainedValue().pressed()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return "无法监听截图快捷键（\(status)）。" }
        }
        var modifiers: UInt32 = 0
        if shortcut.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if shortcut.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        let eventID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, eventID, target, UInt32(kEventHotKeyExclusive), &registered)
        if status == noErr { return nil }
        if status == eventHotKeyExistsErr { return "\(shortcut.title) 已被占用，请更换快捷键。" }
        return "无法使用 \(shortcut.title)（\(status)）。"
    }
}

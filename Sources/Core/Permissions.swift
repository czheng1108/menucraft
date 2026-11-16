import Foundation

enum PermissionStatus: String, Codable {
    case granted, missing, onDemand
}

enum PermissionKind: String, Codable, Hashable {
    case overview, finder, accessibility, files, automation, screenCapture

    static let managed: [Self] = [.finder, .accessibility, .screenCapture, .files, .automation]

    var title: String {
        switch self {
        case .overview: return "权限"
        case .finder: return "Finder 右键扩展"
        case .accessibility: return "辅助功能"
        case .screenCapture: return "录屏"
        case .files: return "文件与文件夹"
        case .automation: return "自动化"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "lock.shield"
        case .finder: return "puzzlepiece.extension"
        case .accessibility: return "hand.raised"
        case .screenCapture: return "viewfinder"
        case .files: return "folder"
        case .automation: return "terminal"
        }
    }

    var settingsButton: String {
        self == .finder ? "打开 Finder 扩展设置" : "打开\(title)设置"
    }

    func statusTitle(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "已授权"
        case .missing: return "未授权"
        case .onDemand: return self == .files ? "按目录授权" : "按需确认"
        }
    }

    static func fileAccessError(_ error: Error) -> PermissionKind? {
        var current = error as NSError
        // Inspect wrapped filesystem errors without treating every operation failure as a permission denial.
        for _ in 0..<8 {
            if current.domain == NSCocoaErrorDomain,
               [CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue].contains(current.code) { return .files }
            if current.domain == NSPOSIXErrorDomain,
               [Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue)].contains(current.code) { return .files }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
            current = underlying
        }
        return nil
    }

    static func automationError(_ number: Int?) -> PermissionKind? { number == -1743 ? .automation : nil }
}

enum PermissionRequirements {
    static func missing(extensionEnabled: Bool, accessibilityEnabled: Bool, scroll: ScrollConfiguration, paused: Bool) -> Set<PermissionKind> {
        var missing = Set<PermissionKind>()
        if !extensionEnabled { missing.insert(.finder) }
        if !accessibilityEnabled && !paused && (scroll.mouse || scroll.trackpad) && (scroll.vertical || scroll.horizontal) { missing.insert(.accessibility) }
        return missing
    }
}

struct PermissionPromptState {
    private var previous = Set<PermissionKind>()
    mutating func shouldPresent(_ missing: Set<PermissionKind>) -> Bool {
        let newlyMissing = missing.subtracting(previous)
        previous = missing
        return !newlyMissing.isEmpty
    }
}

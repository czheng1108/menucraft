import Foundation

enum PermissionKind: String, Codable, Hashable {
    case overview, finder, accessibility, files, automation

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

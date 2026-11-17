import Foundation

@main
struct PermissionTests {
    static func main() throws {
        let scroll = ScrollConfiguration()
        func missing(_ finder: Bool, _ accessibility: Bool, _ configuration: ScrollConfiguration = .init(), _ paused: Bool = false) -> Set<PermissionKind> {
            PermissionRequirements.missing(extensionEnabled: finder, accessibilityEnabled: accessibility, scroll: configuration, paused: paused)
        }
        guard missing(true, true).isEmpty, missing(false, false) == [.finder, .accessibility] else { fatalError("Finder and scroll permission requirements incorrect") }
        var disabled = scroll; disabled.mouse = false; disabled.trackpad = false
        guard missing(true, false, disabled).isEmpty, missing(true, false, scroll, true).isEmpty else { fatalError("Inactive scrolling requests unnecessary authorization") }
        disabled = scroll; disabled.vertical = false; disabled.horizontal = false
        guard missing(true, false, disabled).isEmpty else { fatalError("Disabled directions request authorization") }
        print("PASS Permission overview lists Finder and enabled scrolling only")

        let denied = CocoaError(.fileWriteNoPermission)
        let wrapped = NSError(domain: "Operation", code: 1, userInfo: [NSUnderlyingErrorKey: denied])
        guard PermissionKind.fileAccessError(denied) == .files, PermissionKind.fileAccessError(wrapped) == .files,
              PermissionKind.fileAccessError(POSIXError(.EACCES)) == .files,
              PermissionKind.fileAccessError(CocoaError(.fileNoSuchFile)) == nil,
              PermissionKind.automationError(-1743) == .automation,
              PermissionKind.automationError(-1712) == nil else { fatalError("Permission denials confused with unrelated failures") }
        print("PASS Filesystem and automation denials open guides; missing files and timeouts remain ordinary errors")

        let legacy = Data(#"{"source":"/tmp/example","status":"failed","message":"legacy"}"#.utf8)
        guard try JSONDecoder().decode(ItemResult.self, from: legacy).permission == nil else { fatalError("Old operation records no longer decode") }
        let result = ItemResult(source: "/tmp/example", status: .failed, message: "denied", permission: .files)
        guard try JSONDecoder().decode(ItemResult.self, from: JSONEncoder().encode(result)) == result else { fatalError("Permission context lost across the UI channel") }
        print("PASS Legacy operation records remain readable and permission context survives serialization")
    }
}

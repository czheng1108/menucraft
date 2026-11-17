import AppKit
import Carbon
import Security

enum FinderActionOrigin {
    static func isExpectedExtension(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let bundleURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MenuCraftFinder.appex"),
              Bundle(url: bundleURL)?.bundleIdentifier == "local.menucraft.app.finder" else { return false }
        return isSignedSender(of: event, expectedBundle: bundleURL)
    }

    static func isSignedSender(of event: NSAppleEventDescriptor?, expectedBundle: URL) -> Bool {
        // Launch Services puts the actual caller's kernel audit token on the Apple Event.
        // Its sender PID and the URL fields are not used as identity claims.
        guard let audit = event?.attributeDescriptor(forKeyword: keySenderAuditTokenAttr)?.data,
              audit.count == MemoryLayout<audit_token_t>.size else { return false }
        let token = audit.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        guard token.val.1 == geteuid(), token.val.3 == getuid() else { return false }

        let flags = SecCSFlags()
        let attributes = [kSecGuestAttributeAudit: audit] as CFDictionary
        var guest: SecCode?
        var senderCode: SecStaticCode?
        var senderPath: CFURL?
        var expectedCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, flags, &guest) == errSecSuccess, let guest,
              SecCodeCopyStaticCode(guest, flags, &senderCode) == errSecSuccess, let senderCode,
              SecCodeCopyPath(senderCode, flags, &senderPath) == errSecSuccess, let senderPath,
              (senderPath as URL).resolvingSymlinksInPath().path == expectedBundle.resolvingSymlinksInPath().path,
              SecStaticCodeCreateWithPath(expectedBundle as CFURL, flags, &expectedCode) == errSecSuccess, let expectedCode,
              SecCodeCopyDesignatedRequirement(expectedCode, flags, &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(guest, flags, requirement) == errSecSuccess
    }
}

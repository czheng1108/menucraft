import Foundation
import Darwin

enum StagingCopy {
    static func copy(_ source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // Preserve Foundation's directory/link semantics (including metadata and
        // collision handling). Regular files explicitly request clone-or-copy.
        if values.isDirectory == true || values.isSymbolicLink == true {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_EXCL)
        if copyfile(source.path, destination.path, nil, flags) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: source.path])
        }
    }
}

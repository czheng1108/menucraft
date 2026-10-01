import Foundation
import Darwin

// A private, per-user Unix socket. Frames never touch disk; passwords are request-only.
final class LocalChannel {
    private let fd: Int32
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "local.menucraft.channel.writer")
    private var closed = false
    var onMessage: ((RuntimeMessage) -> Void)?
    var onClose: (() -> Void)?
    static let maxFrame = 16 * 1024 * 1024
    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    static func connect(path: String) throws -> LocalChannel {
        var address = try unixAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        var uid: uid_t = 0, gid: gid_t = 0
        guard result == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
        return LocalChannel(fd: fd)
    }
    static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while let header = readExactly(4) {
                let size = header.reduce(0) { ($0 << 8) | Int($1) }
                guard size > 0, size <= Self.maxFrame, let data = readExactly(size), let message = try? JSONDecoder().decode(RuntimeMessage.self, from: data) else { break }
                onMessage?(message)
            }
            close()
        }
    }
    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count), offset = 0
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            while offset < count {
                lock.lock(); let open = !closed; lock.unlock()
                if !open { return false }
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }
    func send(_ message: RuntimeMessage) {
        writer.async { [weak self] in
            guard let self, let body = try? JSONEncoder().encode(message), body.count <= Self.maxFrame else { return }
            var length = UInt32(body.count).bigEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(body)
            self.lock.lock()
            var ok = !self.closed
            if ok {
                ok = frame.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let n = Darwin.write(self.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { return false }
                        offset += n
                    }
                    return true
                }
            }
            self.lock.unlock()
            if !ok { self.close() }
        }
    }
    func close() {
        lock.lock(); let notify = !closed
        if notify { closed = true; shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        lock.unlock()
        if notify { onClose?() }
    }
    deinit { close() }
}
final class LocalServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "local.menucraft.channel.accept")
    private let path: String
    var onConnect: ((LocalChannel) -> Void)?
    init(path: String) { self.path = path }
    func start() throws {
        var address = try LocalChannel.unixAddress(path)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // The host's single-instance check runs before this server is created.
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { stop(); throw POSIXError(.EADDRINUSE) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let peer = accept(self.fd, nil, nil)
                if peer < 0 { break }
                var uid: uid_t = 0, gid: gid_t = 0
                if getpeereid(peer, &uid, &gid) != 0 || uid != getuid() { Darwin.close(peer); continue }
                _ = fcntl(peer, F_SETFL, 0)
                let channel = LocalChannel(fd: peer)
                DispatchQueue.main.async { self.onConnect?(channel) }
            }
        }
        self.source = source; source.resume()
    }
    func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { Darwin.close(fd); fd = -1; unlink(path) }
    }
    deinit { stop() }
}

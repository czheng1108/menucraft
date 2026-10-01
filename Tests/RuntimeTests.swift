import Foundation

@main
struct RuntimeTests {
    static func main() throws {
        // macOS's per-user temporary path can exceed sockaddr_un's 104-byte limit.
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("mc-ipc-" + UUID().uuidString)
        let path = root.appendingPathComponent("runtime.sock").path
        let server = LocalServer(path: path)
        var connected: LocalChannel?
        server.onConnect = { peer in
            connected = peer
            peer.onMessage = { [weak peer] message in peer?.send(message) }
            peer.start()
        }
        try server.start()
        defer { connected?.close(); server.stop(); try? FileManager.default.removeItem(at: root) }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        guard mode?.intValue == 0o600 else { fatalError("Socket is not private") }
        let client = try LocalChannel.connect(path: path)
        var returned: RuntimeMessage?
        client.onMessage = { message in DispatchQueue.main.async { returned = message } }
        client.start()
        var configuration = AppConfiguration()
        configuration.templates = [.init(id: "custom", title: "日本語", filename: "new.txt", content: String(repeating: "中文 ' ", count: 20000))]
        client.send(.init(kind: "configure", revision: 42, configuration: configuration))
        let deadline = Date().addingTimeInterval(5)
        while returned == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard returned?.revision == 42, returned?.configuration == configuration else { fatalError("IPC changed a large Unicode configuration") }
        client.close()
        print("PASS Private framed channel preserves large configurations and revisions")
    }
}

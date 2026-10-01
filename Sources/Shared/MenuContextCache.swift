import Foundation

struct MenuReference: Codable {
    var contextID: String
    var action: ActionID
    var argument: String?
    var encoded: String {
        "menucraft-menu:" + ((try? JSONEncoder().encode(self))?.base64EncodedString() ?? "")
    }
    static func decode(_ value: String) -> MenuReference? {
        guard value.hasPrefix("menucraft-menu:"), value.utf8.count < 8192,
              let data = Data(base64Encoded: String(value.dropFirst(15))) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
final class MenuContextCache {
    private struct Entry { var context: MenuContext; var created: Date; var bytes: Int }
    private var entries: [String: Entry] = [:]
    private let limit: Int
    init(byteLimit: Int = 16 * 1024 * 1024) { limit = byteLimit }
    func insert(_ context: MenuContext, now: Date = Date()) -> String {
        entries = entries.filter { now.timeIntervalSince($0.value.created) < 300 }
        let bytes = (try? JSONEncoder().encode(context).count) ?? 0
        while entries.values.reduce(0, { $0 + $1.bytes }) + bytes > limit, let oldest = entries.min(by: { $0.value.created < $1.value.created })?.key { entries.removeValue(forKey: oldest) }
        let id = UUID().uuidString; entries[id] = .init(context: context, created: now, bytes: bytes)
        return id
    }
    func request(_ reference: MenuReference, now: Date = Date()) -> ActionRequest? {
        guard let entry = entries[reference.contextID], now.timeIntervalSince(entry.created) < 300 else { entries.removeValue(forKey: reference.contextID); return nil }
        return .init(action: reference.action, argument: reference.argument, context: entry.context)
    }
}

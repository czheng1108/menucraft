import Foundation

struct RuntimeState: Codable {
    var configuration: AppConfiguration
    var notice: String
    var extensionEnabled: Bool
    var extensionConnected: Bool
    var hiddenVisible: Bool
    var cutCount: Int
    var accessibilityEnabled: Bool
    var inputMonitoringEnabled: Bool
    var scrollRunning: Bool
    var scrollPaused: Bool
    var scrollStatus: String
    var volumes: [Favorite]
    var isWorking: Bool
    var progress: Double
    var progressLabel: String
    var resultTitle: String
    var results: [ItemResult]
    var presentsResults: Bool
    var lastRename: RenameJournal?
    var loginEnabled: Bool
    var archiveAvailable: Bool
}
struct WindowRequest: Codable {
    var kind: String
    var files: [String] = []
    var extracting = false
    var argument: String?
}
struct ArchiveTask: Codable {
    var files: [String]
    var extracting: Bool
    var directory: String
    var name: String
    var options: ArchiveConfiguration
    var password: String
    var sameNameFolder: Bool
}
struct RuntimeMessage: Codable {
    var kind: String
    var revision = 0
    var configuration: AppConfiguration?
    var state: RuntimeState?
    var window: WindowRequest?
    var archive: ArchiveTask?
    var entries: [RenameEntry]?
    var flag: Bool?
    var text: String?
}
enum RuntimeAddress {
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MenuCraft", isDirectory: true) }
    static var socket: String { support.appendingPathComponent("runtime.sock").path }
}

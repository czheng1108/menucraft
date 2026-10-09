import SwiftUI

struct PermissionGuideView: View {
    @ObservedObject var model: AppModel
    let kind: PermissionKind
    let close: () -> Void

    private var needsAccessibility: Bool {
        let scroll = model.configuration.scroll
        return !model.scrollPaused && (scroll.mouse || scroll.trackpad) && (scroll.vertical || scroll.horizontal)
    }
    private var permissions: [PermissionKind] {
        kind == .overview ? [.finder] + (needsAccessibility ? [.accessibility] : []) : [kind]
    }
    private func allowed(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .finder: return model.extensionEnabled
        case .accessibility: return model.accessibilityEnabled
        default: return false
        }
    }
    private var ready: Bool { permissions.allSatisfy { allowed($0) } }
    private var hostPath: String {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: ready ? "checkmark.shield" : "hand.raised").font(.system(size: 28)).foregroundStyle(ready ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 7) {
                    Text(ready ? "权限已就绪" : "MenuCraft 授权指引").font(.title2.weight(.semibold))
                    Text("按下面的步骤完成授权，再返回这里。Finder 和辅助功能状态会自动更新。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(permissions, id: \.self) { permission in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(title(permission)).font(.headline)
                                Spacer()
                                if permission == .finder || permission == .accessibility {
                                    Label(allowed(permission) ? "已开启" : "尚未开启", systemImage: allowed(permission) ? "checkmark.circle.fill" : "exclamationmark.circle")
                                        .font(.callout).foregroundStyle(allowed(permission) ? Color.green : Color.secondary)
                                }
                            }
                            Text(purpose(permission)).foregroundStyle(.secondary)
                            ForEach(Array(steps(permission).enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                                    Text(step).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                            }
                            Button(buttonTitle(permission)) { model.openPermissionSettings(permission) }
                                .controlSize(.large)
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if kind == .files || kind == .automation {
                        Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Button("重新检查") { model.refreshSystemState() }
                Spacer()
                Button(ready ? "完成" : (kind == .files || kind == .automation ? "完成后重试操作" : "稍后"), action: close)
                    .keyboardShortcut(.defaultAction)
            }.padding(20)
        }.font(.system(size: 13))
    }

    private func title(_ permission: PermissionKind) -> String {
        switch permission {
        case .finder: return "Finder 右键扩展"
        case .accessibility: return "辅助功能"
        case .files: return "文件夹访问"
        case .automation: return "终端自动化"
        case .overview: return "权限"
        }
    }
    private func purpose(_ permission: PermissionKind) -> String {
        switch permission {
        case .finder: return "开启后，MenuCraft 才能显示在 Finder 的右键菜单中。"
        case .accessibility: return "反向滚动和切换 Finder 隐藏文件需要此权限。"
        case .files: return "当前操作没有访问文件的权限。先检查对应目录的系统授权，再重试。"
        case .automation: return "允许 MenuCraft 控制 \(model.configuration.terminal)，才能让终端进入所选目录。"
        case .overview: return ""
        }
    }
    private func steps(_ permission: PermissionKind) -> [String] {
        switch permission {
        case .finder:
            return ["点击下方按钮，打开系统的 Finder 扩展设置。", "找到 MenuCraft 并开启；系统要求验证时，用触控 ID 或系统密码确认。", "回到 Finder，在文稿、下载、桌面或已添加的目录中右键查看菜单。"]
        case .accessibility:
            return ["点击下方按钮，打开“隐私与安全性 > 辅助功能”。", "开启 MenuCraft；系统要求验证时，用触控 ID 或系统密码确认。", "如果列表中没有 MenuCraft，点击“+”添加：\n\(hostPath)", "如果开关已开启但仍显示未授权，移除旧 MenuCraft 条目，再用“+”重新添加上面的应用。"]
        case .files:
            return ["点击下方按钮，打开“隐私与安全性 > 文件与文件夹”。", "展开 MenuCraft，允许本次操作涉及的目录，例如文稿、桌面或下载。", "如果没有对应条目，重新选择目标目录并重试；系统询问访问时点击“允许”。", "如果仍无法访问，检查文件的读写权限和磁盘是否只读；系统授权不能改变文件本身的权限。"]
        case .automation:
            return ["点击下方按钮，打开“隐私与安全性 > 自动化”。", "展开 MenuCraft，允许控制 \(model.configuration.terminal)。", "如果没有对应条目，回到 Finder 重试“在终端中打开”，在系统询问时点击“允许”。", "完成后重试刚才的操作。"]
        case .overview: return []
        }
    }
    private func buttonTitle(_ permission: PermissionKind) -> String {
        switch permission {
        case .finder: return "打开 Finder 扩展设置"
        case .accessibility: return "打开辅助功能设置"
        case .files: return "打开文件与文件夹设置"
        case .automation: return "打开自动化设置"
        case .overview: return "打开系统设置"
        }
    }
}

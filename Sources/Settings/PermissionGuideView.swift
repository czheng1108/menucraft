import SwiftUI

struct PermissionGuideView: View {
    @ObservedObject var model: AppModel
    let permissions: [PermissionKind]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(permissions, id: \.self) { permission in
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(steps(permission).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(permission.settingsButton) { model.openPermissionSettings(permission) }
                }
                if permission != permissions.last { Divider() }
            }
        }
        .font(.system(size: 13))
        .frame(width: 412, alignment: .leading)
        .padding(20)
    }

    private func steps(_ permission: PermissionKind) -> [String] {
        switch permission {
        case .finder:
            return ["在 Finder 扩展设置中找到 MenuCraft。", "打开开关，再回到 Finder 试一次右键菜单。"]
        case .accessibility:
            return ["在“隐私与安全性 → 辅助功能”中允许 MenuCraft。", "列表中没有 MenuCraft 时，点「+」添加已安装的 MenuCraft。"]
        case .screenCapture:
            return ["在“隐私与安全性”的录屏设置中允许 MenuCraft。", "按系统提示重新打开应用，再试一次截图。"]
        case .files:
            return ["在“隐私与安全性 → 文件与文件夹”中展开 MenuCraft。", "允许本次操作涉及的目录，再重试。"]
        case .automation:
            return ["在“隐私与安全性 → 自动化”中展开 MenuCraft。", "允许控制 \(model.configuration.terminal)，再试一次「在终端中打开」。"]
        case .overview:
            return []
        }
    }
}

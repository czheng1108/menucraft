import AppKit
import SwiftUI

enum CraftIdentity {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.1" }
    static var display: String { "MenuCraft \(version)" }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 12)
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(spacing: 14) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().controlSize(.small).fixedSize(horizontal: true, vertical: false)
        }.padding(.horizontal, 14).padding(.vertical, subtitle == nil ? 10 : 12)
            .frame(minHeight: subtitle == nil ? 44 : 58)
    }
}

struct SettingsToggle: View {
    let title: String
    var symbol: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        SettingsRow(title: title, symbol: symbol) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).accessibilityLabel(title)
        }
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().padding(.horizontal, 14) }
}

extension View {
    func craftPicker() -> some View { self.pickerStyle(.menu).labelsHidden().fixedSize(horizontal: true, vertical: false).controlSize(.small) }
}

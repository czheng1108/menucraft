import AppKit
import SwiftUI

struct CraftCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.system(size: 13, weight: .semibold)); content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }
}

struct ScrollSettingsView: View {
    @ObservedObject var model: AppModel
    private func selection(_ keyPath: WritableKeyPath<ScrollConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { model.configuration.scroll[keyPath: keyPath] }, set: { value in
            var scroll = model.configuration.scroll
            scroll[keyPath: keyPath] = value
            scroll.enabled = true
            model.scrollPaused = false
            model.configuration.scroll = scroll
        })
    }
    var body: some View {
        Text("选中的设备与方向，将与系统当前方向相反。").font(.system(size: 12)).foregroundStyle(.secondary)
        SettingsSection(title: "反向的设备") {
            SettingsToggle(title: "鼠标", symbol: "computermouse", isOn: selection(\.mouse))
            SettingsDivider()
            SettingsToggle(title: "触控板", symbol: "rectangle.and.hand.point.up.left", isOn: selection(\.trackpad))
        }
        SettingsSection(title: "反向的方向") {
            SettingsToggle(title: "纵向", symbol: "arrow.up.arrow.down", isOn: selection(\.vertical))
            SettingsDivider()
            SettingsToggle(title: "横向", symbol: "arrow.left.arrow.right", isOn: selection(\.horizontal))
        }
        Text("关闭设备开关，保留系统原方向。适用于普通鼠标滚轮与 Mac 触控板。").font(.callout).foregroundStyle(.secondary)
        Label(model.accessibilityEnabled ? model.scrollStatus : "请在“权限与设置”中允许辅助功能", systemImage: model.scrollRunning ? "checkmark.circle" : "info.circle").font(.caption).foregroundStyle(.secondary)
    }
}

struct ArchiveOptionsView: View {
    @Binding var options: ArchiveConfiguration
    var body: some View {
        SettingsRow(title: "压缩格式") {
            Picker("压缩格式", selection: $options.format) { ForEach(ArchiveFormat.allCases) { Text($0.title).tag($0) } }.craftPicker()
                .onChange(of: options.format) { value in if !value.supportsEncryption { options.encrypt = false }; if value != .sevenZip { options.encryptNames = false } }
        }
        SettingsDivider()
        SettingsRow(title: "压缩级别") {
            Picker("压缩级别", selection: $options.level) { Text("仅存储").tag(0); Text("标准").tag(5); Text("最高").tag(9) }.craftPicker().disabled(options.format == .tar)
        }
        SettingsDivider()
        SettingsRow(title: "分卷大小") {
            Picker("分卷大小", selection: $options.splitMB) { Text("不分卷").tag(0); Text("100 MB").tag(100); Text("500 MB").tag(500); Text("1 GB").tag(1024); Text("2 GB").tag(2048); if ![0,100,500,1024,2048].contains(options.splitMB) { Text("\(options.splitMB) MB").tag(options.splitMB) } }.craftPicker()
        }
        SettingsDivider()
        SettingsToggle(title: "密码加密（AES-256）", isOn: $options.encrypt).disabled(!options.format.supportsEncryption)
        if options.format == .sevenZip {
            SettingsDivider()
            SettingsToggle(title: "同时加密文件名", isOn: $options.encryptNames).disabled(!options.encrypt)
        }
        if options.format.singleFile { Text("此格式限单个文件；文件夹或多项请选择 TAR 组合格式。").font(.caption).foregroundStyle(.secondary).padding(14) }
    }
}

struct ArchiveSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text("右键选择格式后立即执行，结果保存到原文件所在目录。").font(.system(size: 12)).foregroundStyle(.secondary)
        HStack(spacing: 14) { Button { model.chooseArchiveFiles(extract: false) } label: { Label("选择项目压缩…", systemImage: "archivebox") }.buttonStyle(.borderedProminent); Button { model.chooseArchiveFiles(extract: true) } label: { Label("选择压缩包解压…", systemImage: "shippingbox") }; Spacer(); Label(model.archiveEngine.available ? "引擎就绪" : "引擎缺失", systemImage: model.archiveEngine.available ? "checkmark.circle" : "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }.disabled(model.isWorking)
        SettingsSection(title: "右键压缩默认值") {
            ArchiveOptionsView(options: $model.configuration.archive)
        }
        SettingsSection(title: "解压") {
            SettingsRow(title: "默认位置") {
                Picker("默认解压位置", selection: $model.configuration.archive.extractToSameNameFolder) { Text("同名文件夹").tag(true); Text("当前目录").tag(false) }.craftPicker()
            }
        }
        Text("加密时只询问本次密码；成功后不显示完成弹窗。原文件保留，同名自动加序号。").font(.caption).foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 18) {
            CraftCard(title: "可创建的格式") { Text("ZIP · 7Z · TAR\nTAR.GZ · TAR.BZ2 · TAR.XZ\nGZ · BZ2 · XZ").lineSpacing(8); Text("ZIP 和 7Z 支持 AES-256 加密。7Z 可加密文件名。").font(.caption).foregroundStyle(.secondary) }
            CraftCard(title: "解压支持") { Text("ZIP · 7Z · RAR\nTAR 及 GZ / BZ2 / XZ 组合\n分卷 ZIP / 7Z / RAR").lineSpacing(8); Text("RAR 支持解压。分卷文件必须齐全，并从第一卷开始。").font(.caption).foregroundStyle(.secondary) }
        }
        CraftCard(title: "文件处理方式") { Label("原文件与压缩包保留", systemImage: "checkmark.shield"); Label("同名自动添加序号，不覆盖已有文件", systemImage: "doc.on.doc"); Text("解压前校验路径。当前版本拒绝含符号链接、硬链接或异常路径的归档，并明确报告原因。").font(.caption).foregroundStyle(.secondary) }
        Text("7-Zip 26.03 · 许可证与对应源码随应用提供。").font(.caption).foregroundStyle(.secondary)
    }
}

struct ArchiveEditor: View {
    @ObservedObject var model: AppModel
    let files: [URL]
    let extracting: Bool
    let argument: String?
    var close: () -> Void
    @State private var options = ArchiveConfiguration()
    @State private var directory = ""
    @State private var name = "归档"
    @State private var password = ""
    @State private var confirmation = ""
    @State private var sameNameFolder = true
    private var invalid: String? {
        if directory.isEmpty { return "请选择保存位置。" }
        if !extracting {
            do { try FileOperations.validateName(name) } catch { return error.localizedDescription }
            if options.encrypt && password.isEmpty { return "请输入密码。" }
            if options.encrypt && password != confirmation { return "两次密码不一致。" }
            if options.encrypt && options.format == .zip && (!password.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) || password.utf8.count > 99) { return "ZIP 密码限 1–99 个英文字符、数字或符号；中文密码请选择 7Z。" }
            if options.format.singleFile && (files.count != 1 || FileOperations().isDirectory(files[0])) { return "此格式仅支持单个文件，请选择 TAR 组合格式。" }
        }
        if password.contains("\n") || password.contains("\r") { return "密码不能包含换行。" }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: extracting ? "解压文件" : "创建压缩包", subtitle: "\(files.count) 个项目 · 原文件保留")
            Text(files.prefix(4).map(\.lastPathComponent).joined(separator: "、") + (files.count > 4 ? "…" : "")).lineLimit(2).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    HStack { Text("保存到").frame(width: 70, alignment: .leading); Text(directory).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(directory); Spacer(); Button("选择…") { if let url = model.chooseDirectory(title: "选择保存目录", showSettings: false) { directory = url.path } } }
                    Divider()
                    if extracting {
                        Toggle("解压到同名文件夹", isOn: $sameNameFolder)
                        SecureField("压缩包密码（未加密可留空）", text: $password).textFieldStyle(.roundedBorder)
                        Text("自动添加序号以避开同名项目。多个压缩包分别处理；加密包使用同一个输入密码。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("压缩包名称", text: $name).textFieldStyle(.roundedBorder)
                        ArchiveOptionsView(options: $options)
                        if options.encrypt { SecureField("输入密码", text: $password).textFieldStyle(.roundedBorder); SecureField("再次输入密码", text: $confirmation).textFieldStyle(.roundedBorder) }
                    }
                }.padding(.vertical, 5)
            }
            if let invalid { Label(invalid, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            HStack { Button("取消") { password = ""; confirmation = ""; close() }; Spacer(); Button(extracting ? "开始解压" : "开始压缩") {
                model.executeArchive(files: files, extracting: extracting, directory: URL(fileURLWithPath: directory, isDirectory: true), name: name, options: options, password: password, sameNameFolder: sameNameFolder)
                password = ""; confirmation = ""; close()
            }.buttonStyle(.borderedProminent).disabled(invalid != nil || model.isWorking).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 560, height: 470)
        .onAppear { options = model.configuration.archive; if let argument, let format = ArchiveFormat(rawValue: argument) { options.format = format; if !format.supportsEncryption { options.encrypt = false } }; directory = files.first?.deletingLastPathComponent().path ?? ""; name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "归档"; sameNameFolder = argument != "current"; if argument == "choose", let url = model.chooseDirectory(title: "选择解压目录", showSettings: false) { directory = url.path } }
    }
}

import SwiftUI
import AppKit

enum SettingsPage: String, CaseIterable, Identifiable {
    case menu, scroll, archives, templates, destinations, rename, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .menu: return "右键菜单"; case .scroll: return "滚动控制"; case .archives: return "压缩与解压"; case .templates: return "文件模板"; case .destinations: return "应用与路径"; case .rename: return "批量重命名"; case .settings: return "权限与设置" }
    }
    var symbol: String {
        switch self { case .menu: return "cursorarrow.click"; case .scroll: return "computermouse"; case .archives: return "archivebox"; case .templates: return "doc.badge.plus"; case .destinations: return "square.grid.2x2"; case .rename: return "character.cursor.ibeam"; case .settings: return "slider.horizontal.3" }
    }
    func matches(_ text: String) -> Bool {
        if title.localizedCaseInsensitiveContains(text) { return true }
        let keywords: String
        switch self {
        case .archives: keywords = "密码 加密 格式 分卷 解压 压缩"
        case .settings: keywords = "外观 深色 浅色 登录 启动 权限 扩展名 路径格式"
        case .destinations: keywords = "终端 收藏 常用目录 应用"
        case .templates: keywords = "新建文件 Markdown 模板"
        case .scroll: keywords = "鼠标 触控板 纵向 横向 反向 方向"
        default: keywords = title
        }
        return keywords.localizedCaseInsensitiveContains(text)
    }
}

struct CraftRootView: View {
    @ObservedObject var model: AppModel
    @AppStorage("MenuCraftLastSettingsPage") private var savedPage = SettingsPage.settings.rawValue
    private var page: SettingsPage { SettingsPage(rawValue: savedPage) ?? .settings }
    @State private var search = ""
    private var accent: Color { Color(nsColor: .controlAccentColor) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.rays").font(.system(size: 18, weight: .medium)).foregroundStyle(.white).frame(width: 29, height: 29).background(accent.gradient, in: RoundedRectangle(cornerRadius: 8))
                    if !model.configuration.sidebarCollapsed { Text("MenuCraft").font(.system(size: 16, weight: .semibold)) }
                }.padding(.horizontal, model.configuration.sidebarCollapsed ? 15 : 16).padding(.top, 18).padding(.bottom, 18)
                VStack(spacing: 4) {
                    ForEach(SettingsPage.allCases.filter { $0 != .rename }) { item in
                        Button { savedPage = item.rawValue; search = "" } label: {
                            HStack(spacing: 10) { Image(systemName: item.symbol).font(.system(size: 16)).frame(width: 20); if !model.configuration.sidebarCollapsed { Text(item.title).font(.system(size: 13, weight: page == item ? .semibold : .regular)); Spacer() } }
                                .padding(.horizontal, 12).frame(height: 36).foregroundStyle(page == item ? accent : Color.secondary)
                                .background(page == item ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).help(item.title).accessibilityLabel(item.title)
                    }
                }.padding(.horizontal, 8)
                Spacer()
            }.frame(width: model.configuration.sidebarCollapsed ? 60 : 180).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text(page.title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("查找功能或设置", text: $search).textFieldStyle(.plain) }.padding(.horizontal, 8).frame(width: 180, height: 26).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    Button { model.configuration.sidebarCollapsed.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 17)).frame(width: 30, height: 30) }.buttonStyle(.plain).help(model.configuration.sidebarCollapsed ? "展开侧栏" : "折叠侧栏").accessibilityLabel(model.configuration.sidebarCollapsed ? "展开侧栏" : "折叠侧栏")
                }.padding(.horizontal, 24).frame(height: 46).background(Color(nsColor: .controlBackgroundColor))
                Divider()
                if !model.extensionEnabled {
                    HStack { Image(systemName: "puzzlepiece.extension"); Text("启用 Finder 扩展，将常用操作加入右键菜单。").font(.callout); Spacer(); Button("启用右键扩展") { model.enableExtension() } }.padding(12).background(accent.opacity(0.08))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !search.isEmpty {
                            PageHeading(title: "查找功能", subtitle: "选择下面的项目进入对应设置。")
                            ForEach(SettingsPage.allCases.filter { $0.matches(search) }) { item in Button { savedPage = item.rawValue; search = "" } label: { Label(item.title, systemImage: item.symbol) } }
                            ForEach(ActionID.allCases.filter { $0.title.localizedCaseInsensitiveContains(search) }, id: \.self) { action in Button { savedPage = SettingsPage.menu.rawValue; search = "" } label: { Label(action.title, systemImage: action.symbol) } }
                            if !SettingsPage.allCases.contains(where: { $0.matches(search) }) && !ActionID.allCases.contains(where: { $0.title.localizedCaseInsensitiveContains(search) }) { Text("没有匹配的功能").foregroundStyle(.secondary) }
                        } else {
                            switch page {
                            case .menu: MenuSettingsView(model: model)
                            case .scroll: ScrollSettingsView(model: model)
                            case .archives: ArchiveSettingsView(model: model)
                            case .templates: TemplateSettingsView(model: model)
                            case .destinations: DestinationSettingsView(model: model)
                            case .rename: RenameLandingView(model: model)
                            case .settings: GeneralSettingsView(model: model)
                            }
                        }
                    }.frame(maxWidth: 720, alignment: .topLeading).padding(.horizontal, 24).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .top)
                }.background(Color(nsColor: .windowBackgroundColor)).id(page)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if model.isWorking { HStack { ProgressView(value: model.progress); Button("取消") { model.cancelOperation() } }; Text(model.progressLabel).font(.caption).foregroundStyle(.secondary) }
                    HStack { Circle().fill(model.scrollRunning ? Color.green : Color.secondary).frame(width: 6, height: 6); Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled); Spacer() }
                }.padding(.horizontal, 20).padding(.vertical, 10).background(Color(nsColor: .controlBackgroundColor))
            }
        // Leave native controls at their system default. Passing dynamic NSColor
        // through SwiftUI tint renders switches and pop-up arrows red on macOS 15.6.
        }.font(.system(size: 13)).frame(minWidth: 860, minHeight: 580)
        .sheet(isPresented: $model.presentsResults) { OperationResultsView(model: model) }
    }
}

struct PageHeading: View {
    var title: String; var subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 17, weight: .semibold)); Text(subtitle).foregroundStyle(.secondary).font(.system(size: 12)) } }
}
struct ActionIcon: View {
    var action: ActionID; var colored = true; var hiddenVisible = false
    var body: some View { Image(nsImage: MenuIcons.image(action, colored: colored, hiddenVisible: hiddenVisible) ?? NSImage()).frame(width: 22, height: 22).accessibilityHidden(true) }
}

struct MenuSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var context = "folder"
    var preview: MenuContext {
        .init(directory: "/示例/工作文件", selection: context == "blank" ? [] : context == "archive" ? ["/示例/工作文件/项目资料.zip"] : context == "multi" ? ["/示例/工作文件/笔记.md", "/示例/工作文件/封面.png"] : [context == "folder" ? "/示例/工作文件/项目资料" : "/示例/工作文件/笔记.md"], singleDirectory: context == "folder", isBackground: context == "blank")
    }
    var previewActions: [ActionID] { model.configuration.order.filter { model.configuration.enabled.contains($0) && preview.applies($0, cutCount: model.snapshot.cutCount) } }
    var body: some View {
        Text("选择常用操作，并调整右键菜单顺序。").font(.system(size: 12)).foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("常用操作").font(.headline); Spacer(); Text("\(model.configuration.enabled.count) 项已启用").font(.caption).foregroundStyle(.secondary) }
                VStack(spacing: 0) {
                    ForEach(model.configuration.order, id: \.self) { action in
                        HStack(spacing: 9) {
                            ActionIcon(action: action)
                            Text(action.title).font(.callout)
                            if action.optional { Text("可选").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary)) }
                            Spacer(minLength: 4)
                            VStack(spacing: 2) {
                                Button { model.moveAction(action, by: -1) } label: { Image(systemName: "chevron.up").font(.system(size: 9)) }.disabled(model.configuration.order.first == action).help("上移 \(action.title)")
                                Button { model.moveAction(action, by: 1) } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }.disabled(model.configuration.order.last == action).help("下移 \(action.title)")
                            }.buttonStyle(.borderless)
                            Toggle(action.title, isOn: Binding(get: { model.configuration.enabled.contains(action) }, set: { model.toggle(action, enabled: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("启用 \(action.title)")
                        }.padding(.horizontal, 11).padding(.vertical, 8)
                        if model.configuration.order.last != action { Divider() }
                    }
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                HStack { Button("导入配置…") { model.importConfiguration() }; Button("导出配置…") { model.exportConfiguration() } }.controlSize(.small)
            }.frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 12) {
                Text("右键预览 · 示例").font(.headline)
                HStack { Text("预览情境").foregroundStyle(.secondary); Spacer(); Picker("预览情境", selection: $context) { Text("空白处").tag("blank"); Text("文件夹").tag("folder"); Text("文件").tag("file"); Text("多选").tag("multi"); Text("压缩包").tag("archive") }.craftPicker() }
                VStack(alignment: .leading, spacing: 0) {
                    if context == "multi" { Label("用所选项目新建文件夹", systemImage: "folder.badge.plus").font(.caption).padding(10); Divider() }
                    if model.configuration.grouped { Label("MenuCraft", systemImage: "cursorarrow").font(.callout.weight(.medium)).padding(10); Divider() }
                    ForEach(Array(previewActions.enumerated()), id: \.element) { index, action in
                        HStack(spacing: 8) { ActionIcon(action: action, colored: model.configuration.coloredIcons, hiddenVisible: model.hiddenVisible); Text(action == .hidden && model.hiddenVisible ? "取消显示隐藏文件" : action.title).font(.callout); Spacer(); if [.newFile, .openApp, .transfer, .compress, .extract].contains(action) { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) } }.padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    Label("MenuCraft 设置…", systemImage: "gearshape").font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                }.padding(.vertical, 5).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                NativeMenuPreview(model: model, context: preview).frame(width: 120, height: 26)
                SettingsSection(title: "菜单外观") {
                    SettingsToggle(title: "MenuCraft 子菜单", isOn: $model.configuration.grouped)
                    SettingsDivider()
                    SettingsToggle(title: "彩色功能图标", isOn: $model.configuration.coloredIcons)
                }
                Text("多选新建文件夹沿用 Finder 自带入口；MenuCraft 的菜单项连续显示。").font(.caption).foregroundStyle(.secondary)
                Button("批量重命名…") { model.chooseRenameFiles() }.disabled(model.isWorking)
            }.frame(width: 260, alignment: .topLeading)
        }
    }
}

struct NativeMenuPreview: NSViewRepresentable {
    @ObservedObject var model: AppModel; var context: MenuContext
    func makeCoordinator() -> Coordinator { Coordinator(model: model, context: context) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "查看原生菜单", target: context.coordinator, action: #selector(Coordinator.show(_:))); button.bezelStyle = .rounded; return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.menuContext = self.context }
    final class Coordinator: NSObject {
        let model: AppModel; var menuContext: MenuContext
        init(model: AppModel, context: MenuContext) { self.model = model; self.menuContext = context }
        @objc func show(_ sender: NSButton) {
            let menu = NativeMenuBuilder.build(snapshot: model.snapshot, context: menuContext, target: self, selector: #selector(selected(_:)))
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
        @objc func selected(_ sender: NSMenuItem) { model.notice = "预览：\(sender.title)；这里不会执行文件操作。" }
    }
}

struct TemplateSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selected = "md"
    private func binding(_ path: WritableKeyPath<FileTemplate, String>) -> Binding<String> {
        Binding(get: { model.configuration.templates.first(where: { $0.id == selected })?[keyPath: path] ?? "" }, set: { text in if let index = model.configuration.templates.firstIndex(where: { $0.id == selected }) { model.configuration.templates[index][keyPath: path] = text } })
    }
    var body: some View {
        HStack { Text("在当前文件夹中创建模板文件。").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Button("添加模板") { let template = FileTemplate(id: UUID().uuidString, title: "自定义模板", filename: "新文件.txt", content: "{{name}}\n{{date}}\n"); model.configuration.templates.append(template); selected = template.id } }.controlSize(.small)
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.configuration.templates) { template in
                    Button { selected = template.id } label: { Label(template.title, systemImage: "doc").frame(maxWidth: .infinity, alignment: .leading).padding(9).background(selected == template.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
                }
            }.frame(width: 150)
            Divider()
            if let template = model.configuration.templates.first(where: { $0.id == selected }) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading) { Text("模板名称").font(.caption).foregroundStyle(.secondary); TextField("模板名称", text: binding(\.title)).textFieldStyle(.roundedBorder) }
                    VStack(alignment: .leading) { Text("默认文件名").font(.caption).foregroundStyle(.secondary); TextField("未命名.txt", text: binding(\.filename)).textFieldStyle(.roundedBorder) }
                    VStack(alignment: .leading) { Text("模板内容").font(.caption).foregroundStyle(.secondary); TextEditor(text: binding(\.content)).font(.system(.body, design: .monospaced)).frame(minHeight: 180).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary)) }
                    Text("可用变量：{{name}}   {{date}}   {{year}}").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) { Text("创建后的内容").font(.caption).foregroundStyle(.secondary); Text(template.content.isEmpty ? "（空白文件）" : template.rendered(filename: template.filename)).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                    HStack { Text("修改自动保存，同名时添加序号。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("删除模板", role: .destructive) { model.configuration.templates.removeAll { $0.id == selected }; selected = model.configuration.templates.first?.id ?? "" } }
                }.frame(maxWidth: .infinity)
            } else { Text("添加或选择一个模板").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 300) }
        }
        .onAppear { if !model.configuration.templates.contains(where: { $0.id == selected }) { selected = model.configuration.templates.first?.id ?? "" } }
    }
}

struct DestinationSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        SettingsSection(title: "终端") {
            SettingsRow(title: "默认终端", subtitle: "文件进入父目录，文件夹进入自身。") {
                Picker("默认终端", selection: $model.configuration.terminal) { Text("Terminal").tag("Terminal"); Text("iTerm2").tag("iTerm2") }.craftPicker()
            }
        }
        SettingsSection(title: "常用应用") {
            if model.configuration.apps.isEmpty { Text("暂无常用应用").foregroundStyle(.secondary).padding(14) }
            ForEach(model.configuration.apps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) { Text(app.name); Text(app.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(app.path) }.frame(maxWidth: .infinity, alignment: .leading)
                    if !FileManager.default.fileExists(atPath: app.path) { Text("未找到").font(.caption).foregroundStyle(.secondary) }
                    Button { model.configuration.apps.removeAll { $0.id == app.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除 \(app.name)")
                }.padding(14)
                SettingsDivider()
            }
            HStack { Button("添加应用…") { model.addApp() }; Spacer() }.controlSize(.small).padding(12)
        }
        SettingsSection(title: "常用目录") {
            if model.configuration.favorites.isEmpty { Text("暂无常用目录").foregroundStyle(.secondary).padding(14) }
            ForEach($model.configuration.favorites) { $folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(.cyan).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) { TextField("目录名称", text: $folder.name).textFieldStyle(.plain); Text(folder.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(folder.path) }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.configuration.favorites.removeAll { $0.id == folder.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除 \(folder.name)")
                }.padding(14)
                SettingsDivider()
            }
            HStack { Button("添加目录…") { model.addFavorite() }; Spacer() }.controlSize(.small).padding(12)
        }
        HStack(alignment: .top, spacing: 18) {
            SettingsSection(title: "最近目标") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.configuration.recent, id: \.self) { path in Label { Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle).help(path) } icon: { Image(systemName: "clock.arrow.circlepath") } }
                    if model.configuration.recent.isEmpty { Text("暂无最近目标").foregroundStyle(.secondary) }
                    else { Button("清空") { model.configuration.recent = [] }.controlSize(.small) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsSection(title: "外接磁盘") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.volumes) { volume in Label(volume.name, systemImage: "externaldrive").lineLimit(1).help(volume.path) }
                    if model.volumes.isEmpty { Text("未连接可写磁盘").foregroundStyle(.secondary) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct RenameLandingView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        PageHeading(title: "批量重命名", subtitle: "先看清变化，再开始执行。")
        VStack(alignment: .leading, spacing: 18) {
            Label("可选功能，菜单入口默认关闭", systemImage: "slider.horizontal.3").foregroundStyle(.secondary)
            Text("支持前后缀、连续序号和文字替换，默认保留扩展名。每次执行前展示完整名称预览，并检查重名。")
            Button("选择文件进行重命名…") { model.chooseRenameFiles() }.buttonStyle(.borderedProminent).disabled(model.isWorking)
            Divider()
            if let journal = model.lastRename { Text("最近一次：\(journal.entries.count) 个项目 · \(journal.date.formatted(date: .abbreviated, time: .shortened))").font(.callout); Button("恢复上次名称…") { model.restoreRename() }.disabled(model.isWorking) }
            else { Text("暂无可恢复的重命名记录").font(.callout).foregroundStyle(.secondary) }
            Text("文件内容改变或出现名称冲突后，恢复会停止并说明原因。").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var directoriesExpanded = false
    private var directorySummary: String {
        let names = model.configuration.monitored.prefix(3).map { path in
            switch URL(fileURLWithPath: path).lastPathComponent {
            case "Documents": return "文稿"
            case "Downloads": return "下载"
            case "Desktop": return "桌面"
            default: return URL(fileURLWithPath: path).lastPathComponent
            }
        }
        return names.isEmpty ? "尚未添加目录" : names.joined(separator: "、") + " · \(model.configuration.monitored.count) 个目录"
    }
    var body: some View {
        SettingsSection(title: "通用") {
            SettingsToggle(title: "登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            SettingsDivider()
            SettingsRow(title: "外观") {
                Picker("外观", selection: $model.configuration.appearance) { Text("跟随系统").tag("auto"); Text("浅色").tag("light"); Text("深色").tag("dark") }.craftPicker()
            }
            SettingsDivider()
            SettingsRow(title: "复制路径格式") {
                Picker("复制路径格式", selection: $model.configuration.pathStyle) { ForEach(PathStyle.allCases, id: \.self) { Text($0.title).tag($0) } }.craftPicker()
            }
            SettingsDivider()
            SettingsToggle(title: "复制名称时不包含扩展名", isOn: $model.configuration.nameWithoutExtension)
        }
        SettingsSection(title: "Finder 右键") {
            SettingsRow(title: model.extensionEnabled ? "Finder 扩展已启用" : "Finder 扩展未启用", subtitle: model.extensionConnected ? "已连接，菜单随设置更新。" : "在已添加的目录打开 Finder 后连接。", symbol: "puzzlepiece.extension") {
                Button("管理扩展…") { model.enableExtension() }
            }
            SettingsDivider()
            SettingsRow(title: "显示菜单的目录", subtitle: directorySummary) {
                Button(directoriesExpanded ? "收起" : "查看目录…") { directoriesExpanded.toggle() }
            }
            if directoriesExpanded {
                SettingsDivider()
                ForEach(model.configuration.monitored, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                            Text(path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.configuration.monitored.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除 \(path)")
                    }.padding(.horizontal, 14).padding(.vertical, 9)
                }
                HStack { Button("添加目录…") { model.addMonitoredDirectory() }; Spacer() }.controlSize(.small).padding(14)
            }
        }
        SettingsSection(title: "滚动与隐藏文件") {
            SettingsRow(title: model.accessibilityEnabled ? "辅助功能已允许" : "辅助功能尚未允许", subtitle: "用于反向滚动与切换隐藏文件。", symbol: "hand.raised") {
                Button("查看权限…") { model.requestAccessibility() }
            }
        }
        Text(CraftIdentity.display).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 12).padding(.top, 2)
    }
}

struct OperationResultsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.resultTitle).font(.title2.weight(.semibold))
            Text("\(model.results.filter { $0.status == .completed }.count) 项完成 / \(model.results.count) 项结果").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(model.results.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top) { Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(item.status == .completed ? .green : .orange); VStack(alignment: .leading, spacing: 4) { Text(URL(fileURLWithPath: item.source).lastPathComponent).font(.headline); Text(item.message).font(.callout); if let destination = item.destination { Text(destination).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }; Spacer() }; Divider()
                    }
                }
            }.frame(minHeight: 220, maxHeight: 420)
            HStack { Spacer(); Button("完成") { model.presentsResults = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 620)
    }
}

struct RenameEditor: View {
    @ObservedObject var model: AppModel
    let files: [URL]
    var close: () -> Void
    @State private var mode = "sequence"
    @State private var prefix = "项目资料_"
    @State private var suffix = ""
    @State private var start = 1
    @State private var digits = 2
    @State private var search = ""
    @State private var replacement = ""
    @State private var keepExtension = true
    var entries: [RenameEntry] {
        files.enumerated().map { index, file in
            let isFolder = FileOperations().isDirectory(file)
            let ext = keepExtension && !isFolder && !file.lastPathComponent.hasPrefix(".") ? file.pathExtension : ""
            let base = ext.isEmpty ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent
            let name: String
            switch mode {
            case "replace": name = search.isEmpty ? base : base.replacingOccurrences(of: search, with: replacement)
            case "affix": name = prefix + base + suffix
            default: name = base
            }
            let numbered: String
            if mode == "sequence" { numbered = prefix + String(repeating: "0", count: max(0, digits - String(start + index).count)) + String(start + index) + suffix }
            else { numbered = name }
            return .init(source: file.path, destination: file.deletingLastPathComponent().appendingPathComponent(numbered + (ext.isEmpty ? "" : "." + ext)).path)
        }
    }
    var validation: String? {
        if mode == "replace" && search.isEmpty { return "请输入要替换的文字。" }
        if start < 1 || start > 999999 { return "起始序号应为 1–999999。" }
        do { try FileOperations().validateRename(entries); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "批量重命名", subtitle: "\(files.count) 个项目，执行前检查完整预览。")
            Picker("规则", selection: $mode) { Text("连续序号").tag("sequence"); Text("添加前后缀").tag("affix"); Text("文字替换").tag("replace") }.pickerStyle(.segmented)
            if mode == "replace" { HStack { TextField("查找文字", text: $search); TextField("替换为", text: $replacement) }.textFieldStyle(.roundedBorder) }
            else {
                HStack { TextField("前缀", text: $prefix); TextField("后缀", text: $suffix) }.textFieldStyle(.roundedBorder)
                if mode == "sequence" { HStack { Text("起始序号"); TextField("1", value: $start, format: .number.grouping(.never)).frame(width: 75); Picker("序号位数", selection: $digits) { Text("不补零").tag(1); Text("两位").tag(2); Text("三位").tag(3); Text("四位").tag(4) }.frame(width: 175) } }
            }
            Toggle("保留文件扩展名", isOn: $keepExtension)
            ScrollView {
                VStack(spacing: 0) {
                    HStack { Text("原名称").frame(maxWidth: .infinity, alignment: .leading); Text("新名称").frame(maxWidth: .infinity, alignment: .leading) }.font(.caption).foregroundStyle(.secondary).padding(10).background(.quaternary)
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in HStack { Text(URL(fileURLWithPath: entry.source).lastPathComponent).frame(maxWidth: .infinity, alignment: .leading); Text(URL(fileURLWithPath: entry.destination).lastPathComponent).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity, alignment: .leading) }.padding(10); Divider() }
                }
            }.frame(minHeight: 210)
            if let validation { Label(validation, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
            else { Label("名称检查通过，完成后保留恢复记录。", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout) }
            HStack { Button("取消") { close() }; Spacer(); Button("重命名 \(files.count) 个项目") { model.executeRename(entries, completion: close) }.buttonStyle(.borderedProminent).disabled(validation != nil || model.isWorking) }
        }.padding(26).frame(minWidth: 720, minHeight: 580)
    }
}

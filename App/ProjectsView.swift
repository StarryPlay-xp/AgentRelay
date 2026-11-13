import RelayCore
import SwiftUI

/// 选中的是哪个分组（加一个“未分组”）
enum GroupSelection: Hashable {
    case group(Int)
    case ungrouped
}

/// 项目与分组（设计方案第 7 节、第 16 节）：分组是页面顶上的一排标签，下面是选中分组里的项目
struct ProjectsView: View {
    @Bindable var model: AppModel
    @State private var selection: GroupSelection = .ungrouped
    @State private var newGroupName = ""
    @State private var showingNewGroup = false
    @State private var renaming: GroupRow?
    @State private var renameText = ""
    @State private var deleting: GroupRow?
    @State private var showingAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader("项目与分组", subtitle: "只有同一分组里的会话能互相发信。项目要放进分组并且启用，里面的会话才能传话。") {
                    Button("添加项目…") { showingAdd = true }.buttonStyle(.inkFilled)
                }
                tabs.padding(.top, 34)
                Hairline()
                groupBar.padding(.vertical, 14)
                projectList
            }
            .pagePadding()
        }
        .onAppear {
            if selection == .ungrouped, let first = model.groups.first { selection = .group(first.id) }
        }
        .onChange(of: model.groups) {
            if case .group(let id) = selection, !model.groups.contains(where: { $0.id == id }) { selection = .ungrouped }
        }
        .sheet(isPresented: $showingAdd) {
            AddProjectSheet(model: model, defaultGroup: selectedGroupID)
        }
        .alert("新建分组", isPresented: $showingNewGroup) {
            TextField("分组名", text: $newGroupName)
            Button("新建") {
                model.perform {
                    if let g = try model.store?.addGroup(newGroupName) { selection = .group(g.id) }
                }
                newGroupName = ""
            }
            Button("取消", role: .cancel) { newGroupName = "" }
        } message: {
            Text("只有同一分组里的会话能互相发信。")
        }
        .alert("改分组名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("分组名", text: $renameText)
            Button("保存") {
                if let g = renaming { model.perform { try model.store?.renameGroup(id: g.id, to: renameText) } }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("删除分组“\(deleting?.name ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let g = deleting { model.perform { try model.store?.deleteGroup(id: g.id) } }
                deleting = nil
                selection = .ungrouped
            }
        } message: {
            Text("组里的项目会变为“未分组”，在放进别的分组之前，它们的会话都不能传话。")
        }
    }

    private var selectedGroupID: Int? {
        if case .group(let id) = selection { return id }
        return nil
    }

    private var selectedGroup: GroupRow? {
        selectedGroupID.flatMap { id in model.groups.first { $0.id == id } }
    }

    private var tabs: some View {
        HStack(alignment: .center, spacing: 26) {
            ScrollView(.horizontal, showsIndicators: false) {
                UnderlineTabs(selection: $selection, items: model.groups.map { g in
                    (GroupSelection.group(g.id), g.name, Optional(model.projects.filter { $0.groupID == g.id }.count))
                } + [(GroupSelection.ungrouped, "未分组", Optional(model.projects.filter { $0.groupID == nil }.count))])
            }
            .fixedSize(horizontal: false, vertical: true)
            Button {
                showingNewGroup = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    Text("新建分组")
                }
            }
            .buttonStyle(.inkText)
        }
    }

    private var groupBar: some View {
        HStack(spacing: 14) {
            Text(selectedGroup == nil ? "没放进分组的项目不能传话，放进一个分组后才生效。" : "\(shownProjects.count) 个项目")
                .font(Fonts.small)
                .foregroundStyle(Palette.ink3)
            Spacer()
            if let g = selectedGroup {
                Button("改分组名…") { renameText = g.name; renaming = g }.buttonStyle(.inkText)
                Button("删除分组…") { deleting = g }.buttonStyle(.inkDanger)
            }
        }
    }

    private var shownProjects: [ProjectRow] {
        model.projects.filter { p in
            switch selection {
            case .group(let id): return p.groupID == id
            case .ungrouped: return p.groupID == nil
            }
        }
    }

    @ViewBuilder private var projectList: some View {
        if shownProjects.isEmpty {
            EmptyState("这里还没有项目", symbol: "folder.badge.plus",
                       message: "从 Codex、Claude 已有的项目里勾选，或者手动选一个文件夹。") {
                Button("添加项目…") { showingAdd = true }.buttonStyle(.inkOutline)
            }
            .frame(minHeight: 260)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Hairline()
                ForEach(shownProjects) { p in
                    ProjectRowView(model: model, project: p)
                    Hairline()
                }
            }
        }
    }
}

// MARK: - 一个项目

/// 一个项目：一行摘要，点开可以编辑
struct ProjectRowView: View {
    @Bindable var model: AppModel
    let project: ProjectRow
    @State private var expanded = false
    @State private var editingName = false
    @State private var nameText = ""
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    summary
                }
                .buttonStyle(.plain)
                Toggle("启用", isOn: Binding(
                    get: { project.enabled },
                    set: { on in model.perform { try model.store?.setProjectEnabled(id: project.id, on) } }))
                    .inkSwitch()
                    .help(project.enabled ? "已启用：里面的会话可以传话" : "已停用：里面的会话不能传话")
            }
            .padding(.vertical, 14)
            if expanded {
                ProjectDetail(model: model, project: project,
                              rename: { nameText = project.name; editingName = true },
                              delete: { confirmingDelete = true })
                    .padding(.leading, 26)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .alert("改项目名", isPresented: $editingName) {
            TextField("项目名", text: $nameText)
            Button("保存") { model.perform { try model.store?.renameProject(id: project.id, to: nameText) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除项目“\(project.name)”？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { model.perform { try model.store?.deleteProject(id: project.id) } }
        } message: {
            Text("删除后，这个项目里的会话调用传话工具会被拒绝。已有的信件记录不受影响。")
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.ink3)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 14)
            PlatformDot(platform: project.platform)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(project.name).font(Fonts.rowTitle).foregroundStyle(project.enabled ? Palette.ink : Palette.ink2)
                    Text(project.platform.displayName).font(Fonts.tiny).foregroundStyle(Palette.ink3)
                    if !project.enabled { Text("已停用").font(Fonts.tiny.weight(.medium)).foregroundStyle(Palette.warn) }
                }
                Text(project.mainPaths.first ?? "")
                    .font(Fonts.small)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if !project.extraPaths.isEmpty {
                Text("附加目录 \(project.extraPaths.count)").font(Fonts.tiny).foregroundStyle(Palette.ink3)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 展开后的项目设置
private struct ProjectDetail: View {
    @Bindable var model: AppModel
    let project: ProjectRow
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow {
                    label("来源")
                    Text(project.source.displayName)
                }
                GridRow {
                    label("目录")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(project.mainPaths, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
                GridRow {
                    label("附加目录")
                    extraPaths
                }
                GridRow {
                    label("工作副本")
                    VStack(alignment: .leading, spacing: 4) {
                        CheckRow(isOn: Binding(
                            get: { project.includeWorktrees },
                            set: { on in model.perform { try model.store?.setProjectIncludeWorktrees(id: project.id, on) } })) {
                            Text("包含这个仓库的 Git 工作副本")
                        }
                        Text("在这个仓库的 worktree 里开的会话也算这个项目。另外克隆的独立仓库认不出来，要加成附加目录。")
                            .font(Fonts.tiny)
                            .foregroundStyle(Palette.ink3)
                            .padding(.leading, 24)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    label("分组")
                    MenuPicker(selection: Binding(
                        get: { project.groupID },
                        set: { g in model.perform { try model.store?.setProjectGroup(id: project.id, groupID: g) } }),
                               options: [(Int?.none, "未分组")] + model.groups.map { (Optional($0.id), $0.name) })
                }
            }
            .font(Fonts.small)
            .foregroundStyle(Palette.ink)
            HStack(spacing: 14) {
                Button("改项目名…", action: rename).buttonStyle(.inkOutline)
                Button("删除项目…", action: delete).buttonStyle(.inkDanger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var extraPaths: some View {
        VStack(alignment: .leading, spacing: 6) {
            if project.extraPaths.isEmpty {
                Text("没有").foregroundStyle(Palette.ink3)
            }
            ForEach(project.extraPaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Text(path).textSelection(.enabled)
                    Button {
                        setExtra(project.extraPaths.filter { $0 != path })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.inkText)
                    .help("移除这个附加目录")
                }
            }
            Button("添加附加目录…") {
                if let path = chooseFolder(message: "会话有时在别的目录里干活（例如临时副本），把这些目录加进来") {
                    setExtra(project.extraPaths + [path])
                }
            }
            .buttonStyle(.inkText)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(Palette.ink3).frame(width: 56, alignment: .leading)
    }

    private func setExtra(_ paths: [String]) {
        model.perform { try model.store?.setExtraPaths(id: project.id, paths) }
    }
}

// MARK: - 添加项目

/// 添加项目：Codex、Claude 已有项目里勾选，或手动选文件夹（设计方案第 7.1、7.2 节）
struct AddProjectSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case codex = "Codex", claude = "Claude", manual = "手动"
        var id: String { rawValue }
    }

    @Bindable var model: AppModel
    let defaultGroup: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .codex
    @State private var group: Int?
    @State private var codex: DiscoveryResult?
    @State private var claude: DiscoveryResult?
    @State private var picked: Set<String> = []
    @State private var manualPlatform: Platform = .claude
    @State private var manualPath = ""
    @State private var manualName = ""
    @State private var manualConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("添加项目").font(Fonts.display(22)).foregroundStyle(Palette.ink)
                Text("从 Codex、Claude 已有的项目里勾选，或者手动选一个文件夹。只读取项目名和目录，不改动两边的任何文件。")
                    .font(Fonts.small)
                    .foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            UnderlineTabs(selection: $tab, items: [
                (Tab.codex, "Codex", codex.map { $0.projects.count }),
                (Tab.claude, "Claude", claude.map { $0.projects.count }),
                (Tab.manual, "手动", nil),
            ])
            .padding(.horizontal, 28)
            .padding(.top, 14)
            Hairline()
            Group {
                switch tab {
                case .codex: DiscoveredList(result: codex, platform: .codex, registered: registered(.codex), picked: $picked)
                case .claude: DiscoveredList(result: claude, platform: .claude, registered: registered(.claude), picked: $picked)
                case .manual: manual
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Hairline()
            footer
        }
        .frame(width: 720, height: 540)
        .background(Palette.paper)
        .tint(Palette.ink)
        .onAppear {
            group = defaultGroup ?? model.groups.first?.id
            let discovery = model.runtime.discovery
            Task.detached {
                let c = discovery.codex(), l = discovery.claude()
                await MainActor.run { codex = c; claude = l }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("放进分组").font(Fonts.small).foregroundStyle(Palette.ink2)
            MenuPicker(selection: $group, options: [(Int?.none, "未分组")] + model.groups.map { (Optional($0.id), $0.name) })
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.inkOutline)
                .keyboardShortcut(.cancelAction)
            Button(addTitle) { add() }
                .buttonStyle(.inkFilled)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    /// 已经登记过的目录（同一平台）
    private func registered(_ platform: Platform) -> Set<String> {
        Set(model.projects.filter { $0.platform == platform }.flatMap { $0.mainPaths + $0.extraPaths })
    }

    /// 手动选的目录是否在两边列表里
    private var manualKnown: Bool {
        let n = PathMatcher.normalize(manualPath)
        let all = (codex?.projects ?? []) + (claude?.projects ?? [])
        return all.contains { p in p.platform == manualPlatform && p.paths.contains { PathMatcher.isWithin(n, root: $0) } }
    }

    private var manual: some View {
        VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 16) {
                GridRow {
                    fieldLabel("平台")
                    PillChoice(selection: $manualPlatform, options: [(Platform.codex, "Codex"), (Platform.claude, "Claude")])
                }
                GridRow {
                    fieldLabel("目录")
                    HStack(spacing: 8) {
                        TextField("项目所在的文件夹", text: $manualPath).inkField()
                        Button("选择…") {
                            if let p = chooseFolder(message: "选择要开放传话的项目目录") {
                                manualPath = p
                                if manualName.isEmpty { manualName = (p as NSString).lastPathComponent }
                            }
                        }
                        .buttonStyle(.inkOutline)
                    }
                }
                GridRow {
                    fieldLabel("项目名")
                    TextField("在 AgentRelay 里显示的名字", text: $manualName).inkField().frame(maxWidth: 320)
                }
            }
            if !manualPath.isEmpty && !manualKnown {
                HStack(alignment: .top, spacing: 12) {
                    Capsule().fill(Palette.warn).frame(width: 2)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("这个目录不在 \(manualPlatform.displayName) 已有项目里。确认它就是你要开放传话的目录吗？")
                            .font(Fonts.body)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        CheckRow(isOn: $manualConfirmed) { Text("我确认要添加这个目录").font(Fonts.small) }
                    }
                }
                .padding(.leading, 76)
            }
        }
        .padding(28)
        .onChange(of: manualPath) { manualConfirmed = false }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(Fonts.small).foregroundStyle(Palette.ink3).frame(width: 56, alignment: .leading)
    }

    private var pickedProjects: [DiscoveredProject] {
        let list = tab == .codex ? (codex?.projects ?? []) : tab == .claude ? (claude?.projects ?? []) : []
        return list.filter { picked.contains($0.id) }
    }

    private var addTitle: String {
        tab == .manual ? "添加" : "添加选中的 \(pickedProjects.count) 个"
    }

    private var canAdd: Bool {
        if tab == .manual {
            return !manualPath.isEmpty && !manualName.trimmingCharacters(in: .whitespaces).isEmpty && (manualKnown || manualConfirmed)
        }
        return !pickedProjects.isEmpty
    }

    private func add() {
        model.perform {
            guard let store = model.store else { return }
            if tab == .manual {
                try store.addProject(NewProject(platform: manualPlatform, name: model.uniqueProjectName(manualName, platform: manualPlatform),
                                                source: .manual, groupID: group, mainPaths: [manualPath]))
            } else {
                for p in pickedProjects {
                    try store.addProject(NewProject(platform: p.platform, name: model.uniqueProjectName(p.name, platform: p.platform),
                                                    source: p.source, groupID: group, mainPaths: p.paths))
                }
            }
        }
        if model.errorMessage == nil { dismiss() }
    }
}

/// 从一边读到的已有项目，勾选要添加的
private struct DiscoveredList: View {
    let result: DiscoveryResult?
    let platform: Platform
    let registered: Set<String>
    @Binding var picked: Set<String>

    var body: some View {
        if let result {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(result.notes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 10) {
                            Capsule().fill(Palette.warn).frame(width: 2)
                            Text(note).font(Fonts.small).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 10)
                    }
                    if result.projects.isEmpty {
                        QuietLine("没有找到已有的 \(platform.displayName) 项目，可以用“手动”添加。")
                    }
                    ForEach(result.projects) { p in
                        let already = p.paths.allSatisfy { registered.contains($0) }
                        DiscoveredRow(project: p, already: already, isOn: Binding(
                            get: { already || picked.contains(p.id) },
                            set: { on in if on { picked.insert(p.id) } else { picked.remove(p.id) } }))
                        Hairline()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
        } else {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("正在读取 \(platform.displayName) 已有的项目…").font(Fonts.small).foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DiscoveredRow: View {
    let project: DiscoveredProject
    let already: Bool
    @Binding var isOn: Bool

    var body: some View {
        CheckRow(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(project.name).font(Fonts.body.weight(.medium)).foregroundStyle(Palette.ink)
                    Text(project.source.displayName).font(Fonts.tiny).foregroundStyle(Palette.ink3)
                    if already { Text("已登记").font(Fonts.tiny.weight(.medium)).foregroundStyle(Palette.ok) }
                    if !project.exists { Text("目录已不存在").font(Fonts.tiny.weight(.medium)).foregroundStyle(Palette.warn) }
                }
                ForEach(project.paths, id: \.self) { path in
                    Text(path).font(Fonts.small).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 10)
        .disabled(already)
        .opacity(already ? 0.6 : 1)
    }
}

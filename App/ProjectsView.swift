import RelayCore
import SwiftUI

/// 左边是分组（加一个“未分组”），右边是选中分组里的项目
enum GroupSelection: Hashable {
    case group(Int)
    case ungrouped
}

/// 项目与分组（设计方案第 7 节、第 16 节）
struct ProjectsView: View {
    @Bindable var model: AppModel
    @State private var selection: GroupSelection? = .ungrouped
    @State private var newGroupName = ""
    @State private var showingNewGroup = false
    @State private var renaming: GroupRow?
    @State private var renameText = ""
    @State private var deleting: GroupRow?
    @State private var showingAdd = false

    var body: some View {
        HSplitView {
            groupList.frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
            projectList.frame(minWidth: 480)
        }
        .onAppear {
            if selection == .ungrouped, let first = model.groups.first { selection = .group(first.id) }
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

    private var groupList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("分组") {
                    ForEach(model.groups) { g in
                        Label(g.name, systemImage: "folder").tag(GroupSelection.group(g.id))
                            .contextMenu {
                                Button("改名…") { renameText = g.name; renaming = g }
                                Button("删除…", role: .destructive) { deleting = g }
                            }
                    }
                }
                Label("未分组", systemImage: "tray").tag(GroupSelection.ungrouped)
            }
            Divider()
            HStack {
                Button { showingNewGroup = true } label: { Image(systemName: "plus") }
                    .help("新建分组")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var shownProjects: [ProjectRow] {
        model.projects.filter { p in
            switch selection {
            case .group(let id): return p.groupID == id
            case .ungrouped, .none: return p.groupID == nil
            }
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedGroupID.flatMap { id in model.groups.first { $0.id == id }?.name } ?? "未分组").font(.title3.weight(.semibold))
                Spacer()
                Button("添加项目…") { showingAdd = true }
            }
            .padding(12)
            Divider()
            if shownProjects.isEmpty {
                ContentUnavailableView("这里还没有项目", systemImage: "folder.badge.plus",
                                       description: Text("点“添加项目…”，从 Codex、Claude 已有的项目里勾选，或手动选文件夹。"))
            } else {
                List {
                    ForEach(shownProjects) { p in
                        ProjectRowView(model: model, project: p)
                    }
                }
            }
        }
    }
}

/// 一个项目：可展开编辑
struct ProjectRowView: View {
    @Bindable var model: AppModel
    let project: ProjectRow
    @State private var expanded = false
    @State private var editingName = false
    @State private var nameText = ""
    @State private var confirmingDelete = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("来源", value: project.source.displayName)
                LabeledContent("目录") {
                    VStack(alignment: .leading) {
                        ForEach(project.mainPaths, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
                LabeledContent("附加目录") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(project.extraPaths, id: \.self) { path in
                            HStack {
                                Text(path).textSelection(.enabled)
                                Button { setExtra(project.extraPaths.filter { $0 != path }) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .help("移除这个附加目录")
                            }
                        }
                        Button("添加附加目录…") {
                            if let path = chooseFolder(message: "会话有时在别的目录里干活（例如临时副本），把这些目录加进来") {
                                setExtra(project.extraPaths + [path])
                            }
                        }
                    }
                }
                Toggle("包含这个仓库的 Git 工作副本", isOn: Binding(
                    get: { project.includeWorktrees },
                    set: { on in model.perform { try model.store?.setProjectIncludeWorktrees(id: project.id, on) } }))
                    .help("在这个仓库的 worktree 里开的会话也算这个项目。另外克隆的独立仓库认不出来，要加成附加目录。")
                Picker("分组", selection: Binding(
                    get: { project.groupID },
                    set: { g in model.perform { try model.store?.setProjectGroup(id: project.id, groupID: g) } })) {
                    Text("未分组").tag(Int?.none)
                    ForEach(model.groups) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 320)
                HStack {
                    Button("改名…") { nameText = project.name; editingName = true }
                    Spacer()
                    Button("删除项目…", role: .destructive) { confirmingDelete = true }
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack {
                PlatformBadge(platform: project.platform)
                Text(project.name).fontWeight(.medium)
                Text(project.mainPaths.first ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Toggle("启用", isOn: Binding(
                    get: { project.enabled },
                    set: { on in model.perform { try model.store?.setProjectEnabled(id: project.id, on) } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
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

    private func setExtra(_ paths: [String]) {
        model.perform { try model.store?.setExtraPaths(id: project.id, paths) }
    }
}

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
        VStack(alignment: .leading, spacing: 12) {
            Text("添加项目").font(.title2.weight(.semibold))
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
            switch tab {
            case .codex: discovered(codex, platform: .codex)
            case .claude: discovered(claude, platform: .claude)
            case .manual: manual
            }
            Divider()
            HStack {
                Picker("放进分组", selection: $group) {
                    Text("未分组").tag(Int?.none)
                    ForEach(model.groups) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 280)
                Spacer()
                Button("取消") { dismiss() }
                Button(addTitle) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
        .onAppear {
            group = defaultGroup ?? model.groups.first?.id
            let discovery = model.runtime.discovery
            Task.detached {
                let c = discovery.codex(), l = discovery.claude()
                await MainActor.run { codex = c; claude = l }
            }
        }
    }

    /// 已经登记过的目录（同一平台）
    private func registered(_ platform: Platform) -> Set<String> {
        Set(model.projects.filter { $0.platform == platform }.flatMap { $0.mainPaths + $0.extraPaths })
    }

    @ViewBuilder
    private func discovered(_ result: DiscoveryResult?, platform: Platform) -> some View {
        if let result {
            ForEach(result.notes, id: \.self) { Label($0, systemImage: "info.circle").foregroundStyle(.orange).font(.callout) }
            let done = registered(platform)
            List(result.projects) { p in
                let already = p.paths.allSatisfy { done.contains($0) }
                Toggle(isOn: Binding(
                    get: { already || picked.contains(p.id) },
                    set: { on in if on { picked.insert(p.id) } else { picked.remove(p.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p.name).fontWeight(.medium)
                            Text(p.source.displayName).font(.caption).foregroundStyle(.secondary)
                            if already { Text("已登记").font(.caption).foregroundStyle(.green) }
                            if !p.exists { Text("目录已不存在").font(.caption).foregroundStyle(.orange) }
                        }
                        ForEach(p.paths, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .disabled(already)
            }
            if result.projects.isEmpty { Text("没有找到已有的 \(platform.displayName) 项目，可以用“手动”添加。").foregroundStyle(.secondary) }
        } else {
            ProgressView("正在读取 \(platform.displayName) 已有的项目…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 手动选的目录是否在两边列表里
    private var manualKnown: Bool {
        let n = PathMatcher.normalize(manualPath)
        let all = (codex?.projects ?? []) + (claude?.projects ?? [])
        return all.contains { p in p.platform == manualPlatform && p.paths.contains { PathMatcher.isWithin(n, root: $0) } }
    }

    private var manual: some View {
        Form {
            Picker("平台", selection: $manualPlatform) {
                Text("Codex").tag(Platform.codex)
                Text("Claude").tag(Platform.claude)
            }
            .pickerStyle(.segmented)
            HStack {
                TextField("目录", text: $manualPath)
                Button("选择…") {
                    if let p = chooseFolder(message: "选择要开放传话的项目目录") {
                        manualPath = p
                        if manualName.isEmpty { manualName = (p as NSString).lastPathComponent }
                    }
                }
            }
            TextField("项目名", text: $manualName)
            if !manualPath.isEmpty && !manualKnown {
                Label("这个目录不在 \(manualPlatform.displayName) 已有项目里。确认它就是你要开放传话的目录吗？", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Toggle("我确认要添加这个目录", isOn: $manualConfirmed)
            }
        }
        .formStyle(.grouped)
        .onChange(of: manualPath) { manualConfirmed = false }
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

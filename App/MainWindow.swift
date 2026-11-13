import AppKit
import RelayCore
import SwiftUI

/// 主窗口的页面（设计方案第 16 节；配置向导在第 4 步）
enum Page: String, CaseIterable, Identifiable {
    case overview, projects, sessions, messages, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .projects: return "项目与分组"
        case .sessions: return "会话"
        case .messages: return "消息"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .projects: return "folder"
        case .sessions: return "person.2"
        case .messages: return "envelope"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    /// 选中值必须是可选类型，并且每行用 ForEach 生成、`.tag` 放在最后：
    /// 用 `List(Page.allCases, selection:)` 加非可选选中值时，行的标记是 `Page.id`（文字），和选中值类型对不上，点了不切页
    @State private var selection: Page? = .overview
    private var page: Page { selection ?? .overview }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Page.allCases) { p in
                    Label(p.title, systemImage: p.icon)
                        .badge(p == .overview ? model.attention.count : 0)
                        .tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Group {
                if let error = model.runtime.startupError {
                    ContentUnavailableView("AgentRelay 没有启动", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    switch page {
                    case .overview: OverviewView(model: model)
                    case .projects: ProjectsView(model: model)
                    case .sessions: SessionsView(model: model)
                    case .messages: MessagesView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
            }
            .navigationTitle(page.title)
        }
        .frame(minWidth: 860, minHeight: 540)
        .alert("操作没有完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // 菜单栏应用平时不出现在程序坞；主窗口打开时临时出现，关掉后恢复
        .onAppear {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate()
            AppLog.write("打开主窗口", paths: model.runtime.paths)
        }
        .onDisappear {
            NSApplication.shared.setActivationPolicy(.accessory)
            AppLog.write("关闭主窗口", paths: model.runtime.paths)
        }
    }
}

// MARK: - 小部件

struct PlatformBadge: View {
    let platform: Platform

    var body: some View {
        Text(platform.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(platform == .codex ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
    }
}

enum Format {
    static func time(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "MM-dd HH:mm"
        return f.string(from: d)
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "刚刚" }
        if s < 3_600 { return "\(s / 60) 分钟前" }
        if s < 86_400 { return "\(s / 3_600) 小时前" }
        return "\(s / 86_400) 天前"
    }

    static func status(_ s: MessageStatus) -> String {
        switch s {
        case .queued: return "已排队"
        case .retrying: return "重试中"
        case .pending: return "待读"
        case .read: return "已读"
        case .failed: return "投递失败"
        }
    }

    static func session(_ s: SessionStatus) -> String {
        switch s {
        case .active: return "在用"
        case .pendingHandoff: return "等确认交接"
        case .replaced: return "已被接手"
        case .disabled: return "已停用"
        }
    }

    static func source(_ s: IdentitySource) -> String {
        switch s {
        case .meta: return "Codex 调用元数据"
        case .env: return "Claude 环境变量"
        case .selfReported: return "会话自报"
        }
    }
}

/// 选文件夹
@MainActor
func chooseFolder(message: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = "选择"
    return panel.runModal() == .OK ? panel.url?.path : nil
}

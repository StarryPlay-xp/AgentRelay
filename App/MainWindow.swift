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
}

/// 主窗口：左边是自己画的侧边栏，右边是页面。窗口不显示标题栏，红绿灯直接叠在侧边栏上。
struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var page: Page
    /// 消息页选中的信；概览里点一封信会跳过去
    @State private var openMessage: String?

    init(model: AppModel, page: Page = .overview, openMessage: String? = nil) {
        self.model = model
        _page = State(initialValue: page)
        _openMessage = State(initialValue: openMessage)
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, page: $page)
            Hairline(vertical: true)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.paper)
        .tint(Palette.ink)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 580)
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

    @ViewBuilder private var content: some View {
        if let error = model.runtime.startupError {
            EmptyState("AgentRelay 没有启动", symbol: "exclamationmark.triangle", message: error, tint: Palette.bad)
        } else {
            switch page {
            case .overview:
                OverviewView(model: model, go: { page = $0 }, open: { id in
                    openMessage = id
                    page = .messages
                })
            case .projects: ProjectsView(model: model)
            case .sessions: SessionsView(model: model)
            case .messages: MessagesView(model: model, selection: $openMessage)
            case .settings: SettingsView(model: model)
            }
        }
    }
}

// MARK: - 侧边栏

/// 侧边栏：字样和运行状态、五个页面（⌘1～⌘5）、底部的“全部暂停”
private struct Sidebar: View {
    @Bindable var model: AppModel
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AgentRelay").font(Fonts.wordmark()).foregroundStyle(Palette.ink)
                RunStateLabel(model: model)
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, p in
                    SidebarItem(page: p, key: Character("\(index + 1)"), selected: page == p,
                                badge: p == .overview ? model.attention.count : 0) { page = p }
                }
            }
            .padding(.top, 36)

            Spacer(minLength: 20)
            footer
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.runtime.startupError == nil {
                HStack {
                    Text("全部暂停").font(Fonts.small).foregroundStyle(Palette.ink2)
                    Spacer()
                    Toggle("全部暂停", isOn: Binding(get: { model.paused }, set: { on in model.setPaused(on) }))
                        .inkSwitch()
                }
                .help("暂停后，会话发的信都会被退回；恢复后不补发")
            }
            if model.runtime.isDevelopmentHome {
                Text("开发数据目录")
                    .font(Fonts.tiny)
                    .foregroundStyle(Palette.ink3)
                    .help(model.runtime.paths.home)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }
}

private struct SidebarItem: View {
    let page: Page
    /// ⌘ 加这个键切到这一页
    let key: Character
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(page.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected || hovering ? Palette.ink : Palette.ink2)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.warn)
                        .accessibilityLabel("\(badge) 件待处理")
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(alignment: .leading) {
                if selected {
                    Capsule().fill(Palette.ink).frame(width: 2, height: 16).padding(.leading, 12)
                }
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        .help("\(page.title)（⌘\(String(key))）")
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 格式

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

    /// 信的一句话预览：有主题用主题，没有就用正文第一行
    static func preview(_ m: MessageRow) -> String {
        if let s = m.subject, !s.isEmpty { return s }
        return m.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
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

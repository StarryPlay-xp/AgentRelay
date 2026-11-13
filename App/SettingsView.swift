import AppKit
import RelayCore
import ServiceManagement
import SwiftUI

/// 设置：各项上限、保留期、codex 和 claude 程序路径、通知、登录时启动、数据位置和完全卸载（设计方案第 16 节、第 6.3 节）。
/// 每一节左边写这一节管什么，右边是控件。每一节拆成独立视图：整页写在一个视图里时，Swift 编译器会因类型过大而崩溃。
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader("设置").padding(.bottom, 20)
                LimitsSection(model: model)
                Hairline()
                CodexSection(model: model)
                Hairline()
                ClaudeSection(model: model)
                Hairline()
                NotificationSection()
                Hairline()
                LoginSection(model: model)
                Hairline()
                DataSection(model: model)
            }
            .pagePadding()
        }
    }
}

/// 一节设置：左栏标题和说明，右栏控件（“接入”页也用）
struct SettingsBlock<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(note)
                    .font(Fonts.small)
                    .foregroundStyle(Palette.ink2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 190, alignment: .leading)
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 28)
    }
}

/// 一行开关：左边文字，右边开关
private struct SwitchRow: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Fonts.body).foregroundStyle(Palette.ink)
                if let note { Text(note).font(Fonts.small).foregroundStyle(Palette.ink2) }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).inkSwitch()
        }
    }
}

private struct LimitsSection: View {
    @Bindable var model: AppModel
    @State private var limits = Limits()
    @State private var loaded = false
    @State private var saved = false

    var body: some View {
        SettingsBlock(title: "护栏上限", note: "防止两边无限来回、刷屏。改完点“保存”，立即生效。") {
            LimitRow(label: "同一来回链最多往返", unit: "次", value: $limits.hopLimit, range: 1...50)
            LimitRow(label: "每两个信箱之间每小时最多", unit: "封", value: $limits.pairPerHour, range: 1...1_000)
            LimitRow(label: "全部合计每小时最多", unit: "封", value: $limits.totalPerHour, range: 1...10_000)
            LimitRow(label: "单封正文最多", unit: "字", value: $limits.maxBodyCharacters, range: 1_000...200_000, step: 1_000)
            LimitRow(label: "给 Codex 的信超过这个长度改为长信通知", unit: "字", value: $limits.codexInlineMaxCharacters,
                     range: 1_000...100_000, step: 1_000)
            LimitRow(label: "信件和记录保留", unit: "天", value: $limits.retentionDays, range: 1...365)
            HStack(spacing: 12) {
                Button("保存", action: save).buttonStyle(.inkFilled).disabled(saved)
                Button("恢复默认值") { limits = Limits() }.buttonStyle(.inkText)
                if saved {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        Text("已保存，立即生效")
                    }
                    .font(Fonts.small)
                    .foregroundStyle(Palette.ok)
                }
            }
            .padding(.top, 6)
        }
        .onAppear {
            guard !loaded, let store = model.store else { return }
            limits = store.limits()
            loaded = true
        }
        .onChange(of: limits) { saved = false }
    }

    private func save() {
        model.perform { try model.store?.setLimits(limits) }
        saved = model.errorMessage == nil
    }
}

private struct LimitRow: View {
    let label: String
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(Fonts.body).foregroundStyle(Palette.ink)
            Spacer(minLength: 12)
            ValueStepper(value: $value, range: range, step: step)
            Text(unit).font(Fonts.small).foregroundStyle(Palette.ink2).frame(width: 16, alignment: .leading)
        }
    }
}

private struct CodexSection: View {
    @Bindable var model: AppModel
    @State private var path = ""
    @State private var loaded = false

    var body: some View {
        SettingsBlock(title: "codex 程序", note: "给 Codex 会话送信要用到它。一般不用填，AgentRelay 会自己找。") {
            HStack(spacing: 8) {
                TextField("留空则自动查找", text: $path).inkField()
                Button("选择…", action: choose).buttonStyle(.inkOutline)
                Button("保存") { model.perform { try model.store?.setCodexPath(path.isEmpty ? nil : path) } }
                    .buttonStyle(.inkFilled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("现在会用").font(Fonts.small).foregroundStyle(Palette.ink3)
                if let found = CodexCLI.locate(configuredPath: path.isEmpty ? nil : path) {
                    Text(found).font(Fonts.mono(12, weight: .regular)).foregroundStyle(Palette.ink).textSelection(.enabled)
                } else {
                    Text("找不到 codex 程序").font(Fonts.small.weight(.medium)).foregroundStyle(Palette.bad)
                }
            }
            Text("优先用正在运行的 ChatGPT 里的那份；找不到再用这里填的，最后用 ChatGPT 默认位置和命令行里的 codex。")
                .font(Fonts.small)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            guard !loaded else { return }
            path = model.store?.codexPath() ?? ""
            loaded = true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

private struct ClaudeSection: View {
    @Bindable var model: AppModel
    @State private var path = ""
    @State private var loaded = false

    var body: some View {
        SettingsBlock(title: "claude 程序", note: "接入 Claude 时要用它运行官方命令。一般不用填，AgentRelay 会自己找。") {
            HStack(spacing: 8) {
                TextField("留空则自动查找", text: $path).inkField()
                Button("选择…", action: choose).buttonStyle(.inkOutline)
                Button("保存") {
                    model.perform { try model.store?.setClaudePath(path.isEmpty ? nil : path) }
                    model.refreshIntegrations([.claude])
                }
                .buttonStyle(.inkFilled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("现在会用").font(Fonts.small).foregroundStyle(Palette.ink3)
                if let found = ClaudeCLI.locate(configuredPath: path.isEmpty ? nil : path) {
                    Text(found).font(Fonts.mono(12, weight: .regular)).foregroundStyle(Palette.ink).textSelection(.enabled)
                } else {
                    Text("找不到 claude 程序").font(Fonts.small.weight(.medium)).foregroundStyle(Palette.bad)
                }
            }
            Text("先用这里填的；没填就找命令行装的 claude（~/.local/bin、Homebrew 等位置），最后才用 Claude 桌面版自带的那份。")
                .font(Fonts.small)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            guard !loaded else { return }
            path = model.store?.claudePath() ?? ""
            loaded = true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

private struct NotificationSection: View {
    @AppStorage(Notifier.enabledKey) private var enabled = true

    var body: some View {
        SettingsBlock(title: "通知", note: "不看会话内容，也能知道哪里出了问题。") {
            SwitchRow(title: "有事时发系统通知", note: "投递失败、被拦截、交接、可能卡住等", isOn: $enabled)
            Button("发一条测试通知") { Notifier.shared.post(Notice(kind: "测试", text: "通知正常。")) }
                .buttonStyle(.inkOutline)
        }
    }
}

private struct LoginSection: View {
    @Bindable var model: AppModel
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        SettingsBlock(title: "启动", note: "AgentRelay 不在运行时，会话之间没法传话。") {
            SwitchRow(title: "登录时自动启动 AgentRelay", isOn: Binding(get: { enabled }, set: { on in set(on) }))
            if SMAppService.mainApp.status == .requiresApproval {
                Text("需要在“系统设置 › 通用 › 登录项”里允许 AgentRelay。").font(Fonts.small).foregroundStyle(Palette.warn)
            }
        }
    }

    private func set(_ on: Bool) {
        model.perform {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

private struct DataSection: View {
    @Bindable var model: AppModel
    @State private var uninstalling = false
    private var paths: RelayPaths { model.runtime.paths }

    var body: some View {
        SettingsBlock(title: "数据位置", note: "信件、登记表和日志都只存在这台电脑上。") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                row("运行文件", paths.home)
                row("数据库", paths.database)
                row("日志", paths.logs)
            }
            HStack(spacing: 12) {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: paths.home)])
                }
                .buttonStyle(.inkOutline)
                Button("完全卸载…") { uninstalling = true }
                    .buttonStyle(.inkDanger)
                    .disabled(model.runtime.integrations == nil)
            }
        }
        .sheet(isPresented: $uninstalling) { UninstallSheet(model: model) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(Fonts.small).foregroundStyle(Palette.ink3)
            Text(value).font(Fonts.mono(12, weight: .regular)).foregroundStyle(Palette.ink).textSelection(.enabled)
        }
    }
}

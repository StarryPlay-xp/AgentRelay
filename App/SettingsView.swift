import RelayCore
import ServiceManagement
import SwiftUI

/// 设置：各项上限、保留期、codex 程序路径、通知、登录时启动（设计方案第 16 节；完全卸载在第 4 步）。
/// 每一节拆成独立视图：整页写在一个表单里时，Swift 编译器会因类型过大而崩溃。
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            LimitsSection(model: model)
            CodexSection(model: model)
            NotificationSection()
            LoginSection(model: model)
            DataSection(paths: model.runtime.paths)
        }
        .formStyle(.grouped)
    }
}

private struct LimitsSection: View {
    @Bindable var model: AppModel
    @State private var limits = Limits()
    @State private var loaded = false
    @State private var saved = false

    var body: some View {
        Section("护栏上限") {
            Stepper("同一来回链最多往返 \(limits.hopLimit) 次", value: $limits.hopLimit, in: 1...50)
            Stepper("每两个信箱之间每小时最多 \(limits.pairPerHour) 封", value: $limits.pairPerHour, in: 1...1_000)
            Stepper("全部合计每小时最多 \(limits.totalPerHour) 封", value: $limits.totalPerHour, in: 1...10_000)
            Stepper("单封正文最多 \(limits.maxBodyCharacters) 字", value: $limits.maxBodyCharacters, in: 1_000...200_000, step: 1_000)
            Stepper("给 Codex 超过 \(limits.codexInlineMaxCharacters) 字改为长信通知", value: $limits.codexInlineMaxCharacters, in: 1_000...100_000, step: 1_000)
            Stepper("信件和记录保留 \(limits.retentionDays) 天", value: $limits.retentionDays, in: 1...365)
            HStack {
                Button("保存", action: save)
                Button("恢复默认值") { limits = Limits() }
                if saved { Text("已保存，立即生效").foregroundStyle(.green) }
            }
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

private struct CodexSection: View {
    @Bindable var model: AppModel
    @State private var path = ""
    @State private var loaded = false

    var body: some View {
        Section("codex 程序") {
            HStack {
                TextField("留空则自动查找", text: $path)
                Button("选择…", action: choose)
                Button("保存") { model.perform { try model.store?.setCodexPath(path.isEmpty ? nil : path) } }
            }
            LabeledContent("现在会用", value: CodexCLI.locate(configuredPath: path.isEmpty ? nil : path) ?? "找不到 codex 程序")
            Text("优先用正在运行的 ChatGPT 里的那份；找不到再用这里填的，最后用 ChatGPT 默认位置和命令行里的 codex。")
                .font(.caption).foregroundStyle(.secondary)
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

private struct NotificationSection: View {
    @AppStorage(Notifier.enabledKey) private var enabled = true

    var body: some View {
        Section("通知") {
            Toggle("有事时发系统通知（投递失败、被拦截、交接、可能卡住等）", isOn: $enabled)
            Button("发一条测试通知") { Notifier.shared.post(Notice(kind: "测试", text: "通知正常。")) }
        }
    }
}

private struct LoginSection: View {
    @Bindable var model: AppModel
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Section("启动") {
            Toggle("登录时自动启动 AgentRelay", isOn: Binding(get: { enabled }, set: { on in set(on) }))
            if SMAppService.mainApp.status == .requiresApproval {
                Text("需要在“系统设置 › 通用 › 登录项”里允许 AgentRelay。").font(.caption).foregroundStyle(.orange)
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
    let paths: RelayPaths

    var body: some View {
        Section("数据位置") {
            LabeledContent("运行文件", value: paths.home)
            LabeledContent("数据库", value: paths.database)
            LabeledContent("日志", value: paths.logs)
            Text("“完全卸载”会在配置向导里提供（开发计划第 4 步）。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

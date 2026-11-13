import AppKit
import RelayCore
import SwiftUI

/// 完全卸载（设计方案第 6.3 节）：先说清要做什么、问要不要连数据一起删；做的时候逐步列出结果；
/// 哪一步失败就停下，不做后面的删除。做完由你点“退出”，再把应用拖进废纸篓。
struct UninstallSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deleteData = false

    private var paths: RelayPaths { model.runtime.paths }
    /// 中转服务已经停了（删文件那一步已经开始）
    private var runtimeStopped: Bool { model.runtime.store == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AirmailStripe(height: 3).padding(.horizontal, -28).padding(.top, -28)
            Text("完全卸载 AgentRelay").font(Fonts.display(21)).foregroundStyle(Palette.ink)
            switch model.uninstallPhase {
            case .idle: plan
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在卸载…").font(Fonts.body).foregroundStyle(Palette.ink2)
                }
                steps
            case .failed: failed
            case .done: done
            }
        }
        .padding(28)
        .frame(width: 540, alignment: .leading)
        .background(Palette.paper)
        .interactiveDismissDisabled(model.uninstallPhase == .running || runtimeStopped)
    }

    // MARK: 开始前

    @ViewBuilder private var plan: some View {
        VStack(alignment: .leading, spacing: 10) {
            item(1, "从 Codex、Claude 移除传话工具", "和“接入”页的卸载一样，改之前先备份配置文件。")
            item(2, "关掉“登录时启动”", nil)
            item(3, "删除程序链接和运行文件", "\(paths.bin)\n\(paths.run)")
        }
        CheckRow(isOn: $deleteData) {
            VStack(alignment: .leading, spacing: 3) {
                Text("同时删除数据库、备份、日志和偏好设置").font(Fonts.body).foregroundStyle(Palette.ink)
                Text("\(paths.data)\n\(paths.logs)").font(Fonts.mono(11, weight: .regular)).foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Text("哪一步失败就停下，不做后面的删除。做完后点“退出”，再把 AgentRelay 拖进废纸篓就卸干净了。系统设置“通知”里的 AgentRelay 条目要你自己删。已经开着的会话里的传话服务会运行到会话关闭。")
            .font(Fonts.small)
            .foregroundStyle(Palette.ink2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 12) {
            Spacer()
            Button("取消") { dismiss() }.buttonStyle(.inkOutline).keyboardShortcut(.cancelAction)
            Button("开始卸载") { model.fullUninstall(deleteData: deleteData) }.buttonStyle(.inkFilled)
        }
    }

    private func item(_ n: Int, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(Fonts.small.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink3).frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Fonts.body).foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail).font(Fonts.mono(11, weight: .regular)).foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 进行中和结果

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(model.uninstallSteps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(step.ok ? Palette.ok : Palette.bad)
                        .font(.system(size: 12))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(Fonts.small.weight(.medium)).foregroundStyle(Palette.ink)
                        Text(step.detail).font(Fonts.small).foregroundStyle(Palette.ink2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private var failed: some View {
        steps
        Text(runtimeStopped
             ? "中转服务已经停了，上面打叉的文件没有删掉，请照路径手动删除，然后退出。"
             : "没有删除任何文件，中转服务照常运行。可以到“接入”页看手动步骤，处理好再试一次。")
            .font(Fonts.small)
            .foregroundStyle(Palette.bad)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            if runtimeStopped {
                Button("退出 AgentRelay") { exit(0) }.buttonStyle(.inkFilled)
            } else {
                Button("关闭") {
                    model.uninstallPhase = .idle
                    dismiss()
                }
                .buttonStyle(.inkFilled)
            }
        }
    }

    @ViewBuilder private var done: some View {
        steps
        Text("已经卸载。点“退出”后，把 AgentRelay 拖进废纸篓就卸干净了。")
            .font(Fonts.body)
            .foregroundStyle(Palette.ok)
        HStack {
            Spacer()
            // 直接结束进程：正常退出时系统会保存窗口位置等状态，会把刚删掉的偏好设置又写回去
            Button("退出 AgentRelay") { exit(0) }.buttonStyle(.inkFilled).keyboardShortcut(.defaultAction)
        }
    }
}

import RelayCore
import SwiftUI

/// 消息：按分组、会话、状态筛选；点开看信封、正文和投递过程；按来回链看整串往返（设计方案第 16 节）
struct MessagesView: View {
    @Bindable var model: AppModel
    @State private var groupFilter: String?
    @State private var mailboxFilter: String?
    @State private var statusFilter: MessageStatus?
    @State private var chainFilter: String?
    @State private var selection: MessageRow.ID?

    private var mailboxes: [String] {
        Array(Set(model.messages.flatMap { [$0.fromMailbox, $0.toMailbox] })).sorted()
    }

    private var shown: [MessageRow] {
        model.messages.filter { m in
            if let chainFilter, m.chainID != chainFilter { return false }
            if let mailboxFilter, m.fromMailbox != mailboxFilter && m.toMailbox != mailboxFilter { return false }
            if let statusFilter, m.status != statusFilter { return false }
            if let groupFilter {
                let names = model.sessions.filter { model.groupName(ofProject: $0.project) == groupFilter }.map(\.id)
                if !names.contains(m.fromSession) && !names.contains(m.toSession) { return false }
            }
            return true
        }
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                filters.padding(10)
                Table(shown, selection: $selection) {
                    TableColumn("时间") { m in Text(Format.time(m.createdAt)).monospacedDigit() }.width(90)
                    TableColumn("编号") { m in Text(m.id).monospaced() }.width(150)
                    TableColumn("发信 → 收信") { m in Text("\(m.fromMailbox) → \(m.toMailbox)") }
                    TableColumn("来回链") { m in Text("\(m.chainID) 第 \(m.hop) 次") }.width(120)
                    TableColumn("状态") { m in
                        Text(Format.status(m.status)).foregroundStyle(m.status == .failed ? .red : m.staleFlagged ? .orange : .primary)
                    }.width(80)
                }
            }
            .frame(minHeight: 220)
            detail.frame(minHeight: 180)
        }
    }

    private var filters: some View {
        HStack {
            Picker("分组", selection: $groupFilter) {
                Text("全部分组").tag(String?.none)
                ForEach(model.groups) { Text($0.name).tag(Optional($0.name)) }
            }
            .frame(maxWidth: 180)
            Picker("会话", selection: $mailboxFilter) {
                Text("全部会话").tag(String?.none)
                ForEach(mailboxes, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .frame(maxWidth: 180)
            Picker("状态", selection: $statusFilter) {
                Text("全部状态").tag(MessageStatus?.none)
                ForEach([MessageStatus.queued, .retrying, .pending, .read, .failed], id: \.self) { Text(Format.status($0)).tag(Optional($0)) }
            }
            .frame(maxWidth: 160)
            if let chainFilter {
                Button("只看来回链 \(chainFilter) ✕") { self.chainFilter = nil }
            }
            Spacer()
            Text("共 \(shown.count) 封").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var detail: some View {
        if let m = model.messages.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(m.id).font(.headline).textSelection(.enabled)
                        Spacer()
                        Button("查看整条来回链 \(m.chainID)") { chainFilter = m.chainID }
                    }
                    Text(model.envelope(for: m).render(body: m.body))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    GroupBox("投递过程") {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("发出", value: Format.time(m.createdAt))
                            LabeledContent(m.toPlatform == .codex ? "排进 Codex 队列" : "放进信箱", value: Format.time(m.deliveredAt))
                            LabeledContent("对方读取", value: Format.time(m.readAt))
                            LabeledContent("收到回信", value: m.needsReply ? Format.time(m.repliedAt) : "不需要回复")
                            LabeledContent("当前状态", value: Format.status(m.status) + (m.staleFlagged ? "（可能卡住）" : ""))
                            if let e = m.error { LabeledContent("最近的错误", value: e) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView("选中一封信查看内容", systemImage: "envelope.open")
        }
    }
}

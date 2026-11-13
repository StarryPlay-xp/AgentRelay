import RelayCore
import SwiftUI

/// 概览：顶上一句话说清现在的情况，下面是待处理、各分组在线的会话、最近 20 封信
struct OverviewView: View {
    @Bindable var model: AppModel
    /// 切到别的页面
    var go: (Page) -> Void
    /// 到消息页打开一封信
    var open: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                PageHeader(lines: Headline.lines(model)) {
                    if model.needsSetup, !model.groups.isEmpty {
                        Button("去接入") { go(.setup) }.buttonStyle(.inkFilled)
                    }
                    Button(model.paused ? "恢复传话" : "全部暂停") { model.setPaused(!model.paused) }
                        .buttonStyle(.inkOutline)
                }
                if !model.attention.isEmpty {
                    AttentionSection(model: model)
                }
                OnlineSection(model: model, go: go)
                RecentSection(model: model, go: go, open: open)
            }
            .pagePadding()
        }
    }
}

// MARK: - 待处理

private struct AttentionSection: View {
    @Bindable var model: AppModel

    private var hasEvents: Bool {
        model.attention.contains { if case .event = $0.kind { return true } else { return false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("待处理", note: "\(model.attention.count)") {
                Button("全部标为已处理") { model.perform { try model.store?.acknowledgeAllEvents() } }
                    .buttonStyle(.inkText)
                    .disabled(!hasEvents)
                    .help("交接要逐个确认或拒绝，不会被一起标掉")
            }
            ForEach(Array(model.attention.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Hairline() }
                AttentionRow(model: model, item: item)
            }
        }
    }
}

private struct AttentionRow: View {
    @Bindable var model: AppModel
    let item: AttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Capsule()
                .fill(Headline.color(item))
                .frame(width: 2)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(Fonts.rowTitle).foregroundStyle(Palette.ink)
                Text(item.detail)
                    .font(Fonts.small)
                    .foregroundStyle(Palette.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            Text(Format.time(item.time))
                .font(Fonts.small)
                .monospacedDigit()
                .foregroundStyle(Palette.ink3)
                .padding(.top, 2)
            actions
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch item.kind {
            case .handoff(let mailbox):
                Button("拒绝") { model.perform { try model.service?.rejectHandoff(mailbox: mailbox) } }
                    .buttonStyle(.inkOutline)
                Button("确认交接") { model.perform { _ = try model.service?.confirmHandoff(mailbox: mailbox) } }
                    .buttonStyle(.inkFilled)
            case .event(let id):
                Button("知道了") { model.perform { try model.store?.acknowledgeEvent(id: id) } }
                    .buttonStyle(.inkOutline)
            }
        }
        .fixedSize()
    }
}

// MARK: - 在线的会话

private struct OnlineSection: View {
    @Bindable var model: AppModel
    var go: (Page) -> Void

    private var active: [SessionRow] { model.sessions.filter { $0.status == .active } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("在线的会话", note: model.groups.isEmpty ? nil : "\(active.count)") {
                Button("管理会话") { go(.sessions) }.buttonStyle(.inkText)
            }
            if model.groups.isEmpty {
                HStack(spacing: 14) {
                    QuietLine("还没有分组。到“项目与分组”里新建分组、添加项目后，会话才能登记。")
                    Button("去登记项目") { go(.projects) }.buttonStyle(.inkOutline).fixedSize()
                }
            } else {
                ForEach(model.groups) { g in
                    GroupMembers(model: model, group: g,
                                 members: active.filter { model.groupName(ofProject: $0.project) == g.name },
                                 showName: model.groups.count > 1)
                }
            }
        }
    }
}

private struct GroupMembers: View {
    @Bindable var model: AppModel
    let group: GroupRow
    let members: [SessionRow]
    let showName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showName {
                HStack(spacing: 6) {
                    Text(group.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink2)
                    Text("\(members.count)").font(Fonts.tiny).monospacedDigit().foregroundStyle(Palette.ink3)
                }
                .padding(.top, 14)
                .padding(.bottom, 2)
            }
            if members.isEmpty {
                QuietLine(showName ? "这个分组里没有在用的会话" : "还没有在用的会话")
            }
            ForEach(Array(members.enumerated()), id: \.element.id) { index, s in
                if index > 0 { Hairline() }
                OnlineRow(session: s, waiting: model.waiting.contains(s.mailbox))
            }
        }
    }
}

private struct OnlineRow: View {
    let session: SessionRow
    let waiting: Bool

    var body: some View {
        HStack(spacing: 0) {
            MailboxLabel(name: session.mailbox, platform: session.platform)
                .frame(width: 170, alignment: .leading)
            Text(session.project)
                .font(Fonts.body)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            if session.platform == .claude {
                WaitingLabel(waiting: waiting)
            }
            Spacer(minLength: 12)
            Text(Format.ago(session.lastActiveAt)).font(Fonts.small).foregroundStyle(Palette.ink3)
        }
        .frame(height: 38)
    }
}

// MARK: - 最近的信

private struct RecentSection: View {
    @Bindable var model: AppModel
    var go: (Page) -> Void
    var open: (String) -> Void

    var body: some View {
        let limit = model.store?.limits().hopLimit ?? Limits().hopLimit
        let recent = Array(model.messages.prefix(20))
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("最近的信") {
                Button("查看全部消息") { go(.messages) }.buttonStyle(.inkText)
            }
            if recent.isEmpty {
                QuietLine("还没有信。会话之间传的每一封信都会出现在这里。")
            }
            ForEach(Array(recent.enumerated()), id: \.element.id) { index, m in
                if index > 0 { Hairline() }
                Button { open(m.id) } label: { RecentRow(message: m, hopLimit: limit) }
                    .buttonStyle(RowButtonStyle())
                    .padding(.horizontal, -8)
                    .help("在消息页打开这封信")
            }
        }
    }
}

private struct RecentRow: View {
    let message: MessageRow
    let hopLimit: Int

    var body: some View {
        HStack(spacing: 0) {
            Text(Format.time(message.createdAt))
                .font(Fonts.small)
                .monospacedDigit()
                .foregroundStyle(Palette.ink3)
                .frame(width: 84, alignment: .leading)
            RouteLabel(message: message)
                .frame(width: 270, alignment: .leading)
            Text(message.chainID)
                .font(Fonts.mono(12, weight: .regular))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            HopMeter(hop: message.hop, limit: hopLimit)
            Text("第 \(message.hop) 次").font(Fonts.tiny).foregroundStyle(Palette.ink3).padding(.leading, 8)
            Spacer(minLength: 12)
            MessageStatusLabel(message: message)
        }
        .frame(height: 38)
        .padding(.horizontal, 8)
    }
}

import RelayCore
import SwiftUI

/// 消息：按分组、会话、状态筛选；点开看信封、正文和投递过程；按来回链看整串往返（设计方案第 16 节）。
/// 左边是信件列表，右边把选中的信画成一张信笺。
struct MessagesView: View {
    @Bindable var model: AppModel
    @Binding var selection: String?
    @State private var groupFilter: String?
    @State private var mailboxFilter: String?
    @State private var statusFilter: MessageStatus?
    @State private var chainFilter: String?

    private var mailboxes: [String] {
        Array(Set(model.messages.flatMap { [$0.fromMailbox, $0.toMailbox] })).sorted()
    }

    /// 筛选后的信；只看一条来回链时按时间先后排，方便从头读
    private var shown: [MessageRow] {
        let list = model.messages.filter { m in
            if let chainFilter, m.chainID != chainFilter { return false }
            if let mailboxFilter, m.fromMailbox != mailboxFilter && m.toMailbox != mailboxFilter { return false }
            if let statusFilter, m.status != statusFilter { return false }
            if let groupFilter {
                let ids = model.sessions.filter { model.groupName(ofProject: $0.project) == groupFilter }.map(\.id)
                if !ids.contains(m.fromSession) && !ids.contains(m.toSession) { return false }
            }
            return true
        }
        return chainFilter == nil ? list : list.reversed()
    }

    var body: some View {
        let hopLimit = model.store?.limits().hopLimit ?? Limits().hopLimit
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("消息").font(Fonts.display(27)).foregroundStyle(Palette.ink)
                    filters
                }
                .padding(.horizontal, 28)
                .padding(.top, 50)
                .padding(.bottom, 14)
                Hairline()
                MessageList(messages: shown, hopLimit: hopLimit, selection: $selection)
            }
            .frame(width: 368)
            Hairline(vertical: true)
            detail(hopLimit: hopLimit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                MenuPicker(selection: $groupFilter,
                           options: [(String?.none, "全部分组")] + model.groups.map { (Optional($0.name), $0.name) })
                MenuPicker(selection: $mailboxFilter,
                           options: [(String?.none, "全部会话")] + mailboxes.map { (Optional($0), $0) })
                MenuPicker(selection: $statusFilter,
                           options: [(MessageStatus?.none, "全部状态")]
                               + [MessageStatus.queued, .retrying, .pending, .read, .failed].map { (Optional($0), Format.status($0)) })
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                if let chainFilter {
                    Button {
                        self.chainFilter = nil
                    } label: {
                        HStack(spacing: 6) {
                            Text("只看来回链 \(chainFilter)")
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .buttonStyle(.inkOutline)
                    .help("回到全部的信")
                }
                Text("共 \(shown.count) 封").font(Fonts.small).monospacedDigit().foregroundStyle(Palette.ink3)
            }
        }
    }

    @ViewBuilder private func detail(hopLimit: Int) -> some View {
        if let m = model.messages.first(where: { $0.id == selection }) {
            MessageDetail(model: model, message: m, hopLimit: hopLimit,
                          showChain: { chainFilter = m.chainID },
                          select: { id in selection = id })
                .id(m.id)
        } else {
            EmptyState("选一封信看内容", symbol: "envelope.open",
                       message: model.messages.isEmpty ? "还没有信。会话之间传的每一封信都会出现在这里。"
                           : "能看到信封、正文和投递过程。点“只看来回链”可以按顺序读一整串往返。")
        }
    }
}

// MARK: - 列表

private struct MessageList: View {
    let messages: [MessageRow]
    let hopLimit: Int
    @Binding var selection: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(messages, id: \.id) { m in
                        Button {
                            selection = m.id
                            focused = true
                        } label: {
                            MessageListRow(message: m, hopLimit: hopLimit, selected: m.id == selection)
                        }
                        .buttonStyle(RowButtonStyle(selected: m.id == selection))
                        .id(m.id)
                        Hairline().padding(.leading, 28)
                    }
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    /// 上下方向键换一封
    private func move(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !messages.isEmpty else { return .ignored }
        let current = messages.firstIndex { $0.id == selection }
        let next = current.map { min(max($0 + delta, 0), messages.count - 1) } ?? 0
        selection = messages[next].id
        proxy.scrollTo(messages[next].id)
        return .handled
    }
}

private struct MessageListRow: View {
    let message: MessageRow
    let hopLimit: Int
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RouteLabel(message: message, size: 12)
                Spacer(minLength: 8)
                Text(Format.time(message.createdAt)).font(Fonts.tiny).monospacedDigit().foregroundStyle(Palette.ink3)
            }
            Text(Format.preview(message))
                .font(Fonts.small)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
            HStack(spacing: 8) {
                HopMeter(hop: message.hop, limit: hopLimit)
                Text(message.chainID).font(Fonts.mono(11, weight: .regular)).foregroundStyle(Palette.ink3)
                Spacer(minLength: 8)
                MessageStatusLabel(message: message, font: Fonts.tiny)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Palette.ink).frame(width: 2) }
        }
    }
}

// MARK: - 信笺

private struct MessageDetail: View {
    @Bindable var model: AppModel
    let message: MessageRow
    let hopLimit: Int
    let showChain: () -> Void
    let select: (String) -> Void
    @State private var showRaw = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                LetterCard(model: model, message: message, hopLimit: hopLimit, showChain: showChain, select: select)
                DeliveryTimeline(message: message)
                raw
            }
            .padding(.horizontal, 36)
            .padding(.top, 50)
            .padding(.bottom, 40)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    /// 会话实际收到的样子（信封加正文）
    private var raw: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showRaw.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showRaw ? 90 : 0))
                    Text("会话收到的原文")
                }
            }
            .buttonStyle(.inkText)
            if showRaw {
                Text(model.envelope(for: message).render(body: message.body))
                    .font(Fonts.mono(12, weight: .regular))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct LetterCard: View {
    @Bindable var model: AppModel
    let message: MessageRow
    let hopLimit: Int
    let showChain: () -> Void
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AirmailStripe(height: 5)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let subject = message.subject, !subject.isEmpty {
                        Text(subject).font(Fonts.display(20)).foregroundStyle(Palette.ink)
                    } else {
                        Text("没有主题").font(Fonts.display(20)).foregroundStyle(Palette.ink3)
                    }
                    Spacer(minLength: 8)
                    Text(message.id).font(Fonts.mono(11, weight: .regular)).foregroundStyle(Palette.ink3).textSelection(.enabled)
                }
                fields
                Hairline()
                Text(message.body)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(22)
        }
        .background(Palette.card)
        .overlay(Rectangle().strokeBorder(Palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                label("来自")
                HStack(spacing: 10) {
                    MailboxLabel(name: message.fromMailbox, platform: message.fromPlatform, size: 12)
                    Text("\(message.fromPlatform.displayName)，项目 \(message.fromProject)").foregroundStyle(Palette.ink2)
                }
            }
            GridRow {
                label("寄给")
                HStack(spacing: 10) {
                    MailboxLabel(name: message.toMailbox, platform: message.toPlatform, size: 12)
                    Text(message.toPlatform.displayName).foregroundStyle(Palette.ink2)
                }
            }
            GridRow {
                label("来回链")
                HStack(spacing: 10) {
                    Text(message.chainID).font(Fonts.mono(12))
                    HopMeter(hop: message.hop, limit: hopLimit)
                    Text("第 \(message.hop) 次，最多 \(hopLimit) 次").foregroundStyle(Palette.ink2)
                    Button("只看这条来回链", action: showChain).buttonStyle(.inkText)
                }
            }
            GridRow {
                label("回信")
                HStack(spacing: 10) {
                    Text(message.needsReply ? "需要回信" : "不需要回信")
                    if let reply = message.replyTo {
                        if model.messages.contains(where: { $0.id == reply }) {
                            Button("这是对 \(reply) 的回信") { select(reply) }.buttonStyle(.inkText)
                        } else {
                            Text("这是对 \(reply) 的回信").foregroundStyle(Palette.ink2)
                        }
                    }
                }
            }
        }
        .font(Fonts.small)
        .foregroundStyle(Palette.ink)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(Palette.ink3).gridColumnAlignment(.leading)
    }
}

// MARK: - 投递过程

private struct DeliveryTimeline: View {
    let message: MessageRow

    enum StepState { case done, waiting, warning, failed, skipped }

    private var steps: [(title: String, state: StepState, text: String)] {
        let m = message
        var list: [(String, StepState, String)] = [("发出", .done, Format.time(m.createdAt))]
        let deliverTitle = m.toPlatform == .codex ? "排进 Codex 队列" : "放进信箱"
        if let t = m.deliveredAt {
            list.append((deliverTitle, .done, Format.time(t)))
        } else if m.status == .failed {
            list.append((deliverTitle, .failed, "没有送到"))
        } else if m.status == .retrying {
            list.append((deliverTitle, .warning, "正在重试"))
        } else {
            list.append((deliverTitle, .waiting, "还没送到"))
        }
        if let t = m.readAt {
            list.append(("对方读取", .done, Format.time(t)))
        } else {
            list.append(("对方读取", .waiting, "还没读"))
        }
        if !m.needsReply {
            list.append(("收到回信", .skipped, "不需要回信"))
        } else if let t = m.repliedAt {
            list.append(("收到回信", .done, Format.time(t)))
        } else if m.staleFlagged {
            list.append(("收到回信", .warning, "等了很久，可能卡住"))
        } else {
            list.append(("收到回信", .waiting, "还没回"))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("投递过程") {
                HStack(spacing: 6) {
                    Text("现在").font(Fonts.small).foregroundStyle(Palette.ink3)
                    MessageStatusLabel(message: message)
                }
            }
            .padding(.bottom, 6)
            let all = steps
            ForEach(Array(all.enumerated()), id: \.offset) { index, step in
                StepRow(title: step.title, state: step.state, text: step.text, last: index == all.count - 1)
            }
            if let error = message.error {
                HStack(alignment: .top, spacing: 12) {
                    Capsule().fill(Palette.bad).frame(width: 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近的错误").font(Fonts.small.weight(.medium)).foregroundStyle(Palette.ink)
                        Text(error).font(Fonts.small).foregroundStyle(Palette.ink2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 14)
            }
        }
    }
}

private struct StepRow: View {
    let title: String
    let state: DeliveryTimeline.StepState
    let text: String
    let last: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                marker.frame(width: 10, height: 10).padding(.top, 4)
                if !last { Rectangle().fill(Palette.line).frame(width: 1).frame(maxHeight: .infinity) }
            }
            .frame(width: 10)
            Text(title)
                .font(Fonts.small)
                .foregroundStyle(state == .done ? Palette.ink : Palette.ink2)
                .frame(width: 110, alignment: .leading)
            Text(text)
                .font(Fonts.small)
                .monospacedDigit()
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .frame(height: 34, alignment: .top)
    }

    @ViewBuilder private var marker: some View {
        switch state {
        case .done: Circle().fill(Palette.ink)
        case .waiting: Circle().strokeBorder(Palette.ink3, lineWidth: 1.2)
        case .warning: Circle().strokeBorder(Palette.warn, lineWidth: 1.5)
        case .failed: Circle().fill(Palette.bad)
        case .skipped: Circle().strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
        }
    }

    private var color: Color {
        switch state {
        case .done: return Palette.ink2
        case .waiting, .skipped: return Palette.ink3
        case .warning: return Palette.warn
        case .failed: return Palette.bad
        }
    }
}

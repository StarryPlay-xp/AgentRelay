import RelayCore
import SwiftUI

/// 会话：信箱名、平台、项目、编号缩写、最后活动、是否在等信；停用、启用、改名、交接（设计方案第 16 节）。
/// 按会话所属项目现在的分组分节；不在任何分组里的会话单独一节（它们不能传话）。
struct SessionsView: View {
    @Bindable var model: AppModel
    @State private var renaming: SessionRow?
    @State private var renameText = ""

    /// 每节：标题和会话；在用、等交接的排前面，停用和已被接手的排后面
    private var sections: [(title: String, sessions: [SessionRow])] {
        func rank(_ s: SessionRow) -> Int {
            switch s.status {
            case .pendingHandoff: return 0
            case .active: return 1
            case .disabled: return 2
            case .replaced: return 3
            }
        }
        func sorted(_ list: [SessionRow]) -> [SessionRow] {
            list.sorted { (rank($0), $0.mailbox) < (rank($1), $1.mailbox) }
        }
        var result: [(String, [SessionRow])] = model.groups.compactMap { g in
            let list = model.sessions.filter { model.groupName(ofProject: $0.project) == g.name }
            return list.isEmpty ? nil : (g.name, sorted(list))
        }
        let loose = model.sessions.filter { model.groupName(ofProject: $0.project) == nil }
        if !loose.isEmpty { result.append(("不在任何分组里", sorted(loose))) }
        return result
    }

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                EmptyState("还没有会话登记", symbol: "person.2",
                           message: "登记过的项目里，会话第一次调用 relay_register 后会出现在这里。")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        PageHeader("会话", subtitle: "信箱名就是发信时写的地址。停用的会话不能收发信；换了会话想接手同一个信箱时，要在这里确认。")
                        ForEach(sections, id: \.title) { section in
                            SessionSection(model: model, title: section.title, sessions: section.sessions) { s in
                                renameText = s.mailbox
                                renaming = s
                            }
                        }
                    }
                    .pagePadding()
                }
            }
        }
        .alert("改信箱名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("信箱名", text: $renameText)
            Button("保存") {
                if let s = renaming { model.perform { try model.service?.renameMailbox(session: s.id, to: renameText) } }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text("小写字母、数字和 -，以字母或数字开头，最长 32 个字符。Claude 会话改名后，下次读信时会拿到新的等信命令。")
        }
    }
}

private struct SessionSection: View {
    @Bindable var model: AppModel
    let title: String
    let sessions: [SessionRow]
    let rename: (SessionRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title, note: "\(sessions.count)")
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, s in
                if index > 0 { Hairline() }
                SessionRowView(model: model, session: s, rename: rename)
            }
        }
    }
}

private struct SessionRowView: View {
    @Bindable var model: AppModel
    let session: SessionRow
    let rename: (SessionRow) -> Void

    private var dimmed: Bool { session.status == .disabled || session.status == .replaced }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    MailboxLabel(name: session.mailbox, platform: session.platform, size: 14)
                    if session.status != .active {
                        Text(Format.session(session.status))
                            .font(Fonts.tiny.weight(.medium))
                            .foregroundStyle(session.status == .pendingHandoff ? Palette.warn : Palette.ink3)
                    }
                }
                details
            }
            .opacity(dimmed ? 0.55 : 1)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                if session.platform == .claude && session.status == .active {
                    WaitingLabel(waiting: model.waiting.contains(session.mailbox))
                }
                Text(Format.ago(session.lastActiveAt)).font(Fonts.small).foregroundStyle(Palette.ink3)
                    .help("最后活动：\(Format.time(session.lastActiveAt))")
            }
            HStack(spacing: 6) { SessionActions(model: model, session: session, rename: rename) }
                .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .contextMenu { SessionActions(model: model, session: session, rename: rename) }
    }

    private var details: some View {
        HStack(spacing: 16) {
            Text(session.platform.displayName)
            Text(session.project).lineLimit(1)
            Text(String(session.sessionID.prefix(8)) + "…")
                .font(Fonts.mono(11, weight: .regular))
                .help("会话编号，完整编号只在本机显示")
            Text("身份：\(Format.source(session.identitySource))")
                .foregroundStyle(session.identitySource == .selfReported ? Palette.warn : Palette.ink2)
                .help(session.identitySource == .selfReported ? "取不到可靠来源，用的是会话自己报的编号" : "")
        }
        .font(Fonts.small)
        .foregroundStyle(Palette.ink2)
        .padding(.leading, 12)
    }
}

/// 一个会话能做的操作：行尾按钮和右键菜单共用
private struct SessionActions: View {
    @Bindable var model: AppModel
    let session: SessionRow
    let rename: (SessionRow) -> Void

    var body: some View {
        switch session.status {
        case .active:
            Button("改名…") { rename(session) }.buttonStyle(.inkText)
            Button("停用") { model.perform { try model.service?.setSessionEnabled(id: session.id, false) } }
                .buttonStyle(.inkOutline)
        case .disabled:
            Button("启用") { model.perform { try model.service?.setSessionEnabled(id: session.id, true) } }
                .buttonStyle(.inkOutline)
        case .pendingHandoff:
            Button("拒绝交接") { model.perform { try model.service?.rejectHandoff(mailbox: session.mailbox) } }
                .buttonStyle(.inkOutline)
            Button("确认交接") { model.perform { _ = try model.service?.confirmHandoff(mailbox: session.mailbox) } }
                .buttonStyle(.inkFilled)
        case .replaced:
            EmptyView()
        }
    }
}

import RelayCore
import SwiftUI

/// 会话：信箱名、平台、项目、编号缩写、最后活动、是否在等信；停用、启用、改名、交接（设计方案第 16 节）
struct SessionsView: View {
    @Bindable var model: AppModel
    @State private var selection: SessionRow.ID?
    @State private var renaming: SessionRow?
    @State private var renameText = ""

    private var selected: SessionRow? { model.sessions.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if model.sessions.isEmpty {
                ContentUnavailableView("还没有会话登记", systemImage: "person.2",
                                       description: Text("登记项目里的会话第一次调用 relay_register 后会出现在这里。"))
            } else {
                Table(model.sessions, selection: $selection) {
                    TableColumn("信箱名") { s in Text(s.mailbox).fontWeight(.medium) }
                    TableColumn("平台") { s in PlatformBadge(platform: s.platform) }.width(70)
                    TableColumn("项目") { s in Text(s.project) }
                    TableColumn("会话编号") { s in Text(String(s.sessionID.prefix(8)) + "…").monospaced().help("完整编号只在本机显示") }.width(100)
                    TableColumn("状态") { s in Text(Format.session(s.status)).foregroundStyle(s.status == .active ? .primary : .secondary) }.width(90)
                    TableColumn("等信") { s in
                        if s.platform == .claude {
                            Text(model.waiting.contains(s.mailbox) ? "正在等" : "没在等")
                                .foregroundStyle(model.waiting.contains(s.mailbox) ? .green : .orange)
                        } else {
                            Text("不需要").foregroundStyle(.secondary)
                        }
                    }.width(70)
                    TableColumn("最后活动") { s in Text(Format.ago(s.lastActiveAt)) }.width(90)
                    TableColumn("身份来源") { s in
                        Text(Format.source(s.identitySource)).foregroundStyle(s.identitySource == .selfReported ? .orange : .secondary)
                    }
                }
                .contextMenu(forSelectionType: SessionRow.ID.self) { ids in
                    if let id = ids.first, let s = model.sessions.first(where: { $0.id == id }) { actions(for: s) }
                }
            }
            Divider()
            HStack {
                if let s = selected {
                    Text("选中：\(s.mailbox)").foregroundStyle(.secondary)
                    actions(for: s)
                } else {
                    Text("选中一个会话可以停用、改名或处理交接。").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
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

    @ViewBuilder
    private func actions(for s: SessionRow) -> some View {
        switch s.status {
        case .active:
            Button("改名…") { renameText = s.mailbox; renaming = s }
            Button("停用") { model.perform { try model.service?.setSessionEnabled(id: s.id, false) } }
        case .disabled:
            Button("启用") { model.perform { try model.service?.setSessionEnabled(id: s.id, true) } }
        case .pendingHandoff:
            Button("确认交接") { model.perform { _ = try model.service?.confirmHandoff(mailbox: s.mailbox) } }
            Button("拒绝交接") { model.perform { try model.service?.rejectHandoff(mailbox: s.mailbox) } }
        case .replaced:
            EmptyView()
        }
    }
}

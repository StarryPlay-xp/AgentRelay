import RelayCore
import SwiftUI

/// 概览：待处理、各分组的会话、最近 20 封信
struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Label(model.paused ? "已暂停全部传话" : "正在运行", systemImage: model.paused ? "pause.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.paused ? .orange : .green)
                        .font(.headline)
                    Text("今天 \(model.todayCount) 封信").foregroundStyle(.secondary)
                    Spacer()
                    Button(model.paused ? "恢复传话" : "全部暂停") { model.setPaused(!model.paused) }
                }

                attentionSection
                groupsSection
                recentSection
            }
            .padding(20)
        }
    }

    @ViewBuilder private var attentionSection: some View {
        GroupBox {
            if model.attention.isEmpty {
                Text("没有待处理的事。").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.attention) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.callout).textSelection(.enabled)
                                Text(Format.time(item.time)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            switch item.kind {
                            case .handoff(let mailbox):
                                Button("确认交接") { model.perform { _ = try model.service?.confirmHandoff(mailbox: mailbox) } }
                                Button("拒绝") { model.perform { try model.service?.rejectHandoff(mailbox: mailbox) } }
                            case .event(let id):
                                Button("知道了") { model.perform { try model.store?.acknowledgeEvent(id: id) } }
                            }
                        }
                        Divider()
                    }
                    Button("全部标为已处理") { model.perform { try model.store?.acknowledgeAllEvents() } }
                        .disabled(!model.attention.contains { if case .event = $0.kind { return true } else { return false } })
                }
            }
        } label: {
            Label("待处理（\(model.attention.count)）", systemImage: "bell")
        }
    }

    @ViewBuilder private var groupsSection: some View {
        GroupBox {
            let active = model.sessions.filter { $0.status == .active }
            if model.groups.isEmpty {
                Text("还没有分组。到“项目与分组”里新建分组、添加项目后，会话才能登记。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.groups) { g in
                        let members = active.filter { model.groupName(ofProject: $0.project) == g.name }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.name).font(.headline)
                            if members.isEmpty {
                                Text("没有在用的会话").font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(members, id: \.id) { s in
                                HStack {
                                    PlatformBadge(platform: s.platform)
                                    Text(s.mailbox).fontWeight(.medium)
                                    Text(s.project).foregroundStyle(.secondary)
                                    Spacer()
                                    if s.platform == .claude {
                                        Text(model.waiting.contains(s.mailbox) ? "正在等信" : "没在等信")
                                            .foregroundStyle(model.waiting.contains(s.mailbox) ? .green : .orange)
                                    }
                                    Text(Format.ago(s.lastActiveAt)).foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("各分组的会话", systemImage: "person.2")
        }
    }

    @ViewBuilder private var recentSection: some View {
        GroupBox {
            if model.messages.isEmpty {
                Text("还没有信。").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.messages.prefix(20), id: \.id) { m in
                        HStack {
                            Text(Format.time(m.createdAt)).monospacedDigit().foregroundStyle(.secondary)
                            Text("\(m.fromMailbox) → \(m.toMailbox)")
                            Text("\(m.chainID) 第 \(m.hop) 次").foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.status(m.status)).foregroundStyle(m.status == .failed ? .red : .secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        } label: {
            Label("最近的信", systemImage: "envelope")
        }
    }
}

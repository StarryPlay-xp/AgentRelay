import Foundation

/// 界面上“待处理”的一项（设计方案第 16 节“概览”）
public struct AttentionItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// 新会话想接手信箱，等你确认或拒绝
        case handoff(mailbox: String)
        /// 一条需要你知道的事件（投递失败、拦截、超限、可能卡住等），看过后可以标为已处理
        case event(id: Int)
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let time: Date
}

extension Store {
    /// 改信箱名：全局唯一
    public func renameMailbox(session id: Int, to name: String) throws {
        try MailboxName.validate(name)
        try locked {
            guard try db.query("SELECT 1 FROM sessions WHERE mailbox = ? AND id != ? AND status IN ('active', 'pending_handoff')",
                               [.text(name), .int(id)]).isEmpty else {
                throw RelayError(.mailboxTaken, "信箱名 \(name) 已被占用")
            }
            try db.query("UPDATE sessions SET mailbox = ? WHERE id = ?", [.text(name), .int(id)])
        }
    }

    /// 删除一个会话的登记（拒绝交接时用）
    public func deleteSession(id: Int) throws {
        try locked { try db.query("DELETE FROM sessions WHERE id = ?", [.int(id)]) }
    }

    /// 还没标为已处理的事件
    public func unacknowledgedEvents(kinds: [String], since: Date) throws -> [EventRow] {
        guard !kinds.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
        return try locked {
            try db.query("SELECT * FROM events WHERE acknowledged = 0 AND time >= ? AND kind IN (\(marks)) ORDER BY id DESC",
                         [SQLValue(since)] + kinds.map { .text($0) }).map {
                EventRow(id: $0.int("id")!, time: $0.date("time")!, kind: $0.string("kind")!, summary: $0.string("summary")!)
            }
        }
    }

    public func acknowledgeEvent(id: Int) throws {
        try locked { try db.query("UPDATE events SET acknowledged = 1 WHERE id = ?", [.int(id)]) }
    }

    public func acknowledgeAllEvents() throws {
        try locked { try db.query("UPDATE events SET acknowledged = 1 WHERE acknowledged = 0") }
    }

    /// 今天（本地时间）的信件数
    public func countMessagesToday(now: Date = Date(), calendar: Calendar = .current) throws -> Int {
        try countMessages(since: calendar.startOfDay(for: now))
    }
}

/// 用户在界面上的操作（第 2 步由 relayd 控制台调用的那些在 RelayService.swift 里）
extension RelayService {
    /// 要在概览里提醒你的事件种类
    public static let attentionKinds = ["投递失败", "拦截", "超限", "可能卡住", "未读", "Codex 重启", "身份", "登记表", "拒绝"]

    /// 待处理：等确认的交接，以及最近 7 天还没标为已处理的提醒
    public func attentionItems() throws -> [AttentionItem] {
        let now = clock()
        var items: [AttentionItem] = try store.sessions(status: .pendingHandoff).map { s in
            let holder = try store.activeSession(mailbox: s.mailbox)
            let minutes = holder.map { Int(now.timeIntervalSince($0.lastActiveAt) / 60) }
            return AttentionItem(
                id: "handoff-\(s.id)", kind: .handoff(mailbox: s.mailbox), title: "\(s.mailbox) 想由新会话接手",
                detail: "新会话在项目 \(s.project)" + (minutes.map { "，旧会话最后活动 \($0) 分钟前" } ?? "，旧会话已不在用"),
                time: s.registeredAt)
        }
        items += try store.unacknowledgedEvents(kinds: Self.attentionKinds, since: now.addingTimeInterval(-7 * 86_400)).map {
            AttentionItem(id: "event-\($0.id)", kind: .event(id: $0.id), title: $0.kind, detail: $0.summary, time: $0.time)
        }
        return items.sorted { $0.time > $1.time }
    }

    /// 拒绝交接：删掉等待中的新会话登记，旧会话照常使用
    public func rejectHandoff(mailbox name: String) throws {
        try locked {
            guard let pending = try store.pendingHandoff(mailbox: name) else {
                throw RelayError(.invalidArgument, "信箱 \(name) 没有待确认的交接")
            }
            try store.deleteSession(id: pending.id)
            try store.addEvent(kind: "交接", summary: "拒绝了新会话接手 \(name)", at: clock())
        }
    }

    /// 停用或重新启用一个会话
    public func setSessionEnabled(id: Int, _ enabled: Bool) throws {
        try locked {
            guard let s = try store.session(id: id) else { throw RelayError(.invalidArgument, "没有这个会话") }
            if enabled {
                guard s.status == .disabled else { return }
                if let holder = try store.activeSession(mailbox: s.mailbox), holder.id != s.id {
                    throw RelayError(.mailboxTaken, "信箱名 \(s.mailbox) 已被别的会话使用，请先给这个会话改名")
                }
                try store.setStatus(session: id, .active)
            } else {
                guard s.status == .active else { return }
                try store.setStatus(session: id, .disabled)
            }
            try store.addEvent(kind: "会话", summary: "\(enabled ? "启用" : "停用")了 \(s.mailbox)", at: clock())
        }
    }

    /// 改信箱名；Claude 会话的未读标记跟着搬到新名字下（它要重新运行等信命令，下次读信时会拿到新命令）
    public func renameMailbox(session id: Int, to name: String) throws {
        try locked {
            guard let s = try store.session(id: id) else { throw RelayError(.invalidArgument, "没有这个会话") }
            guard s.mailbox != name else { return }
            try store.renameMailbox(session: id, to: name)
            if s.platform == .claude {
                try mailbox.setUnread(0, mailbox: s.mailbox)
                try mailbox.setUnread(try store.unreadCount(toSession: id), mailbox: name)
            }
            try store.addEvent(kind: "会话", summary: "\(s.mailbox) 改名为 \(name)", at: clock())
        }
    }
}

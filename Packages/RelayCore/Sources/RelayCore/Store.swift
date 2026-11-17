import Foundation

public enum SessionStatus: String, Codable, Sendable {
    /// 在用
    case active
    /// 新会话想接手这个信箱，等你确认（设计方案第 8.3 节）
    case pendingHandoff = "pending_handoff"
    /// 已被新会话接手
    case replaced
    /// 停用
    case disabled
}

/// 会话编号从哪来（设计方案第 8.1 节）
public enum IdentitySource: String, Codable, Sendable {
    /// Codex 每次调用请求里的 `_meta.threadId`
    case meta
    /// Claude 的 relay-mcp 进程环境变量
    case env
    /// 会话自报（只在取不到上面两种时退回使用）
    case selfReported = "self"
}

public struct SessionRow: Sendable, Equatable {
    public let id: Int
    public let platform: Platform
    public let sessionID: String
    public let hostSessionID: String?
    public let project: String
    public let group: String
    public let mailbox: String
    public let recordCwd: String
    public let identitySource: IdentitySource
    public let status: SessionStatus
    public let registeredAt: Date
    public let lastActiveAt: Date
}

public enum MessageStatus: String, Codable, Sendable {
    /// 已排进 Codex 会话的队列
    case queued
    /// 投递失败，正在重试
    case retrying
    /// 等对方读取（Claude 的信，或给 Codex 的长信）
    case pending
    /// 已读
    case read
    /// 投递失败
    case failed
    /// 立即引导：中转核心已接受，等对方下一个动作之前注入
    case steerWaiting = "steer_waiting"
    /// 立即引导：已注入对方正在进行的一轮，等对方用 relay_inbox 读取
    case injected
    /// 结果未知（例如排队命令超时、又没能核对），需要人去看
    case unknown
}

/// 投递方式：排队（对方这一轮结束后新开一轮处理）或立即引导（注入对方正在进行的一轮）
public enum DeliveryMode: String, Codable, Sendable {
    case queue
    case steer
}

/// 立即引导送不进去时怎么办：默认不降级；`queue` 表示改为排队，回执里写明实际用了排队
public enum SteerFallback: String, Codable, Sendable {
    case none
    case queue
}

public struct MessageRow: Sendable, Equatable {
    public let id: String
    public let chainID: String
    public let hop: Int
    public let fromSession: Int
    public let toSession: Int
    public let fromMailbox: String
    public let toMailbox: String
    public let fromPlatform: Platform
    public let toPlatform: Platform
    public let fromProject: String
    public let replyTo: String?
    public let subject: String?
    public let body: String
    public let needsReply: Bool
    public let status: MessageStatus
    public let queueRef: String?
    public let error: String?
    public let createdAt: Date
    public let deliveredAt: Date?
    public let readAt: Date?
    public let repliedAt: Date?
    public let staleFlagged: Bool
    /// 发信方要求的投递方式（旧信没有这一列，按排队算）
    public let requestedDelivery: DeliveryMode
    /// 实际采用的投递方式；还没投出去时为 nil
    public let actualDelivery: DeliveryMode?
    /// 引导信被注入到对方的哪一轮
    public let codexTurnID: String?
    /// 引导信由哪个钩子注入：PreToolUse / PostToolUse / Stop
    public let codexHookEvent: String?
}

/// 写信时的输入，编号由信件库分配
public struct MessageDraft: Sendable {
    public var chainID: String?
    public var hop: Int
    public var from: SessionRow
    public var to: SessionRow
    public var replyTo: String?
    public var subject: String?
    public var body: String
    public var needsReply: Bool
    public var status: MessageStatus
    public var createdAt: Date
    public var requestedDelivery: DeliveryMode
    public var actualDelivery: DeliveryMode?

    public init(chainID: String?, hop: Int, from: SessionRow, to: SessionRow, replyTo: String?, subject: String?,
                body: String, needsReply: Bool, status: MessageStatus, createdAt: Date,
                requestedDelivery: DeliveryMode = .queue, actualDelivery: DeliveryMode? = nil) {
        self.chainID = chainID
        self.hop = hop
        self.from = from
        self.to = to
        self.replyTo = replyTo
        self.subject = subject
        self.body = body
        self.needsReply = needsReply
        self.status = status
        self.createdAt = createdAt
        self.requestedDelivery = requestedDelivery
        self.actualDelivery = actualDelivery
    }
}

/// Codex 会话的轮次状态，由 relay-hook 上报（立即引导用来判断对方是否正在一轮里）
public struct CodexTurnState: Sendable, Equatable {
    public let sessionID: String
    public let turnID: String?
    /// 正在一轮里（上报 UserPromptSubmit、PreToolUse、PostToolUse 后为真；放行结束、中断后为假）
    public let active: Bool
    public let updatedAt: Date
    /// 上报时运行钩子的 Codex 后台服务进程号；它退出了，这份状态就作废
    public let hostPID: Int32?
}

public struct EventRow: Sendable, Equatable {
    public let id: Int
    public let time: Date
    public let kind: String
    /// 摘要，不含信件正文
    public let summary: String
}

/// 本机数据库（设计方案第 17 节）。第 2 步的分组和项目来自登记表文件，不在库里。
/// 所有方法都加锁，可以在多个线程里调用。
public final class Store: @unchecked Sendable {
    let db: SQLiteDatabase
    private let lock = NSLock()

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            platform TEXT NOT NULL,
            session_id TEXT NOT NULL,
            host_session_id TEXT,
            project TEXT NOT NULL,
            group_name TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            record_cwd TEXT NOT NULL,
            identity_source TEXT NOT NULL,
            status TEXT NOT NULL,
            registered_at REAL NOT NULL,
            last_active_at REAL NOT NULL,
            UNIQUE (platform, session_id)
        );
        CREATE INDEX IF NOT EXISTS sessions_mailbox ON sessions (mailbox, status);
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            chain_id TEXT NOT NULL,
            hop INTEGER NOT NULL,
            from_session INTEGER NOT NULL,
            to_session INTEGER NOT NULL,
            from_mailbox TEXT NOT NULL,
            to_mailbox TEXT NOT NULL,
            from_platform TEXT NOT NULL,
            to_platform TEXT NOT NULL,
            from_project TEXT NOT NULL,
            reply_to TEXT,
            subject TEXT,
            body TEXT NOT NULL,
            needs_reply INTEGER NOT NULL,
            status TEXT NOT NULL,
            queue_ref TEXT,
            error TEXT,
            created_at REAL NOT NULL,
            delivered_at REAL,
            read_at REAL,
            replied_at REAL,
            stale_flagged INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS messages_created ON messages (created_at);
        CREATE INDEX IF NOT EXISTS messages_to ON messages (to_session, status);
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            time REAL NOT NULL,
            kind TEXT NOT NULL,
            summary TEXT NOT NULL
        );
        INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1');
        """)
        // 第 3 步：分组、项目进数据库（设计方案第 17 节）；事件可以标为“已处理”
        try db.execute("""
        CREATE TABLE IF NOT EXISTS groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS projects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            platform TEXT NOT NULL,
            name TEXT NOT NULL UNIQUE,
            source TEXT NOT NULL,
            group_id INTEGER REFERENCES groups (id) ON DELETE SET NULL,
            include_worktrees INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS project_paths (
            project_id INTEGER NOT NULL REFERENCES projects (id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            kind TEXT NOT NULL,
            PRIMARY KEY (project_id, path)
        );
        """)
        let eventColumns = try db.query("PRAGMA table_info(events)").compactMap { $0.string("name") }
        if !eventColumns.contains("acknowledged") {
            try db.execute("ALTER TABLE events ADD COLUMN acknowledged INTEGER NOT NULL DEFAULT 0")
        }
        // 第 4 步：配置改动记录（设计方案第 17 节）
        try db.execute("""
        CREATE TABLE IF NOT EXISTS config_changes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            time REAL NOT NULL,
            platform TEXT NOT NULL,
            action TEXT NOT NULL,
            target TEXT NOT NULL,
            file_existed INTEGER NOT NULL,
            backup_path TEXT,
            snapshot_path TEXT,
            summary TEXT NOT NULL,
            ok INTEGER NOT NULL
        );
        """)
        // 第 4 版：投递方式（排队 / 立即引导）和引导信的注入记录；Codex 会话的轮次状态
        let messageColumns = try db.query("PRAGMA table_info(messages)").compactMap { $0.string("name") }
        for (name, type) in [("requested_delivery", "TEXT"), ("actual_delivery", "TEXT"), ("codex_turn_id", "TEXT"), ("codex_hook_event", "TEXT")]
        where !messageColumns.contains(name) {
            try db.execute("ALTER TABLE messages ADD COLUMN \(name) \(type)")
        }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS codex_turns (
            session_id TEXT PRIMARY KEY,
            turn_id TEXT,
            active INTEGER NOT NULL,
            updated_at REAL NOT NULL,
            host_pid INTEGER
        );
        """)
        try db.execute("UPDATE meta SET value = '4' WHERE key = 'schema_version'")
    }

    /// 提前关闭数据库（完全卸载删除数据文件之前用）；关闭后再调用任何方法都会报错
    public func close() {
        locked { db.close() }
    }

    @discardableResult
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: 会话

    @discardableResult
    public func insertSession(platform: Platform, sessionID: String, hostSessionID: String?, project: String,
                              group: String, mailbox: String, recordCwd: String, identitySource: IdentitySource,
                              status: SessionStatus, at now: Date) throws -> SessionRow {
        try locked {
            try db.query("""
            INSERT INTO sessions (platform, session_id, host_session_id, project, group_name, mailbox, record_cwd,
                                  identity_source, status, registered_at, last_active_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (platform, session_id) DO UPDATE SET
                host_session_id = excluded.host_session_id, project = excluded.project, group_name = excluded.group_name,
                mailbox = excluded.mailbox, record_cwd = excluded.record_cwd, identity_source = excluded.identity_source,
                status = excluded.status, registered_at = excluded.registered_at, last_active_at = excluded.last_active_at
            """, [.text(platform.rawValue), .text(sessionID), SQLValue(hostSessionID), .text(project), .text(group),
                  .text(mailbox), .text(recordCwd), .text(identitySource.rawValue), .text(status.rawValue),
                  SQLValue(now), SQLValue(now)])
            return try sessionRows("WHERE platform = ? AND session_id = ?", [.text(platform.rawValue), .text(sessionID)])[0]
        }
    }

    public func session(platform: Platform, sessionID: String) throws -> SessionRow? {
        try locked { try sessionRows("WHERE platform = ? AND session_id = ?", [.text(platform.rawValue), .text(sessionID)]).first }
    }

    public func session(id: Int) throws -> SessionRow? {
        try locked { try sessionRows("WHERE id = ?", [.int(id)]).first }
    }

    /// 某个信箱当前在用的会话
    public func activeSession(mailbox: String) throws -> SessionRow? {
        try locked { try sessionRows("WHERE mailbox = ? AND status = 'active'", [.text(mailbox)]).first }
    }

    public func pendingHandoff(mailbox: String) throws -> SessionRow? {
        try locked {
            try sessionRows("WHERE mailbox = ? AND status = 'pending_handoff' ORDER BY registered_at DESC", [.text(mailbox)]).first
        }
    }

    public func sessions(group: String? = nil, status: SessionStatus? = nil) throws -> [SessionRow] {
        try locked {
            var conds: [String] = []
            var params: [SQLValue] = []
            if let group { conds.append("group_name = ?"); params.append(.text(group)) }
            if let status { conds.append("status = ?"); params.append(.text(status.rawValue)) }
            let whereSQL = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
            return try sessionRows(whereSQL + " ORDER BY mailbox", params)
        }
    }

    public func setStatus(session id: Int, _ status: SessionStatus) throws {
        try locked { try db.query("UPDATE sessions SET status = ? WHERE id = ?", [.text(status.rawValue), .int(id)]) }
    }

    public func touch(session id: Int, at now: Date) throws {
        try locked { try db.query("UPDATE sessions SET last_active_at = ? WHERE id = ?", [SQLValue(now), .int(id)]) }
    }

    /// 确认交接：旧会话标为已被接手，新会话转为在用（一次事务）
    public func confirmHandoff(from old: Int?, to new: Int, at now: Date) throws {
        try locked {
            try db.transaction {
                if let old { try db.query("UPDATE sessions SET status = 'replaced' WHERE id = ?", [.int(old)]) }
                try db.query("UPDATE sessions SET status = 'active', last_active_at = ? WHERE id = ?", [SQLValue(now), .int(new)])
                // 还没读的信改寄给新会话
                if let old {
                    try db.query("UPDATE messages SET to_session = ? WHERE to_session = ? AND status IN ('pending', 'retrying', 'injected')",
                                 [.int(new), .int(old)])
                }
            }
        }
    }

    private func sessionRows(_ tail: String, _ params: [SQLValue]) throws -> [SessionRow] {
        try db.query("SELECT * FROM sessions " + tail, params).map { r in
            SessionRow(
                id: r.int("id")!, platform: Platform(rawValue: r.string("platform")!)!, sessionID: r.string("session_id")!,
                hostSessionID: r.string("host_session_id"), project: r.string("project")!, group: r.string("group_name")!,
                mailbox: r.string("mailbox")!, recordCwd: r.string("record_cwd")!,
                identitySource: IdentitySource(rawValue: r.string("identity_source")!) ?? .selfReported,
                status: SessionStatus(rawValue: r.string("status")!) ?? .disabled,
                registeredAt: r.date("registered_at")!, lastActiveAt: r.date("last_active_at")!)
        }
    }

    // MARK: 信件

    /// 存一封信并分配编号：信件编号按天递增，新来回链全局递增。
    public func insertMessage(_ d: MessageDraft, timeZone: TimeZone = .current) throws -> MessageRow {
        try locked {
            try db.transaction {
                let day = RelayIDs.day(of: d.createdAt, timeZone: timeZone)
                var seq = 1
                if try metaValue("msg_day") == day, let last = try metaValue("msg_seq").flatMap(Int.init) { seq = last + 1 }
                try setMeta("msg_day", day)
                try setMeta("msg_seq", String(seq))
                let id = RelayIDs.messageID(day: day, sequence: seq)
                var chain = d.chainID
                if chain == nil {
                    let c = (try metaValue("chain_seq").flatMap(Int.init) ?? 0) + 1
                    try setMeta("chain_seq", String(c))
                    chain = RelayIDs.chainID(sequence: c)
                }
                try db.query("""
                INSERT INTO messages (id, chain_id, hop, from_session, to_session, from_mailbox, to_mailbox, from_platform,
                                      to_platform, from_project, reply_to, subject, body, needs_reply, status, created_at,
                                      requested_delivery, actual_delivery)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(id), .text(chain!), .int(d.hop), .int(d.from.id), .int(d.to.id), .text(d.from.mailbox),
                      .text(d.to.mailbox), .text(d.from.platform.rawValue), .text(d.to.platform.rawValue),
                      .text(d.from.project), SQLValue(d.replyTo), SQLValue(d.subject), .text(d.body), SQLValue(d.needsReply),
                      .text(d.status.rawValue), SQLValue(d.createdAt), .text(d.requestedDelivery.rawValue),
                      SQLValue(d.actualDelivery?.rawValue)])
                return try messageRows("WHERE id = ?", [.text(id)])[0]
            }
        }
    }

    public func message(id: String) throws -> MessageRow? {
        try locked { try messageRows("WHERE id = ?", [.text(id)]).first }
    }

    /// 等某个会话读取的信（含已注入的引导信），按时间先后
    public func unread(toSession id: Int) throws -> [MessageRow] {
        try locked { try messageRows("WHERE to_session = ? AND status IN ('pending', 'injected') ORDER BY created_at, id", [.int(id)]) }
    }

    public func unreadCount(toSession id: Int) throws -> Int {
        try locked {
            try db.query("SELECT COUNT(*) AS n FROM messages WHERE to_session = ? AND status IN ('pending', 'injected')",
                         [.int(id)])[0].int("n") ?? 0
        }
    }

    public func markRead(_ ids: [String], at now: Date) throws {
        try locked {
            try db.transaction {
                for id in ids {
                    try db.query("UPDATE messages SET status = 'read', read_at = ? WHERE id = ? AND status IN ('pending', 'injected')",
                                 [SQLValue(now), .text(id)])
                }
            }
        }
    }

    /// - Parameter actual: 实际采用的投递方式；nil 表示不改
    public func updateDelivery(id: String, status: MessageStatus, queueRef: String? = nil, error: String? = nil,
                               actual: DeliveryMode? = nil, at now: Date) throws {
        try locked {
            let delivered: SQLValue = (status == .queued || status == .pending || status == .injected) ? SQLValue(now) : .null
            try db.query("""
            UPDATE messages SET status = ?, queue_ref = COALESCE(?, queue_ref), error = ?,
                delivered_at = COALESCE(?, delivered_at), actual_delivery = COALESCE(?, actual_delivery) WHERE id = ?
            """, [.text(status.rawValue), SQLValue(queueRef), SQLValue(error), delivered, SQLValue(actual?.rawValue), .text(id)])
        }
    }

    // MARK: 立即引导

    /// 等注入某个会话的引导信，按时间先后
    public func steerWaiting(toSession id: Int) throws -> [MessageRow] {
        try locked { try messageRows("WHERE to_session = ? AND status = 'steer_waiting' ORDER BY created_at, id", [.int(id)]) }
    }

    /// 所有等注入的引导信（定时检查超时用）
    public func allSteerWaiting() throws -> [MessageRow] {
        try locked { try messageRows("WHERE status = 'steer_waiting' ORDER BY created_at, id", []) }
    }

    /// 认领引导信：只认领仍在等注入的，返回真正认领到的那些（同一封信只会被认领一次）
    public func claimSteer(_ ids: [String], turnID: String?, event: String, at now: Date) throws -> [MessageRow] {
        try locked {
            try db.transaction {
                var claimed: [String] = []
                for id in ids {
                    try db.query("""
                    UPDATE messages SET status = 'injected', actual_delivery = 'steer', codex_turn_id = ?, codex_hook_event = ?,
                        delivered_at = ?, error = NULL WHERE id = ? AND status = 'steer_waiting'
                    """, [SQLValue(turnID), .text(event), SQLValue(now), .text(id)])
                    if db.changes > 0 { claimed.append(id) }
                }
                return try claimed.map { try messageRows("WHERE id = ?", [.text($0)])[0] }
            }
        }
    }

    /// 某一轮里已经注入了几封引导信
    public func injectedCount(toSession id: Int, turnID: String) throws -> Int {
        try locked {
            try db.query("SELECT COUNT(*) AS n FROM messages WHERE to_session = ? AND codex_turn_id = ? AND actual_delivery = 'steer'",
                         [.int(id), .text(turnID)])[0].int("n") ?? 0
        }
    }

    /// 把等注入的引导信标为投递失败（不转排队），返回被标的那些
    @discardableResult
    public func failSteerWaiting(_ ids: [String], reason: String, at now: Date) throws -> [MessageRow] {
        try locked {
            try db.transaction {
                var failed: [String] = []
                for id in ids {
                    try db.query("UPDATE messages SET status = 'failed', error = ? WHERE id = ? AND status = 'steer_waiting'",
                                 [.text(reason), .text(id)])
                    if db.changes > 0 { failed.append(id) }
                }
                return try failed.map { try messageRows("WHERE id = ?", [.text($0)])[0] }
            }
        }
    }

    public func codexTurn(sessionID: String) throws -> CodexTurnState? {
        try locked {
            try db.query("SELECT * FROM codex_turns WHERE session_id = ?", [.text(sessionID)]).first.map {
                CodexTurnState(sessionID: $0.string("session_id")!, turnID: $0.string("turn_id"), active: $0.bool("active"),
                               updatedAt: $0.date("updated_at")!, hostPID: $0.int("host_pid").map { Int32($0) })
            }
        }
    }

    public func setCodexTurn(sessionID: String, turnID: String?, active: Bool, hostPID: Int32?, at now: Date) throws {
        try locked {
            try db.query("""
            INSERT INTO codex_turns (session_id, turn_id, active, updated_at, host_pid) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (session_id) DO UPDATE SET turn_id = excluded.turn_id, active = excluded.active,
                updated_at = excluded.updated_at, host_pid = excluded.host_pid
            """, [.text(sessionID), SQLValue(turnID), SQLValue(active), SQLValue(now), hostPID.map { .int(Int($0)) } ?? .null])
        }
    }

    public func markReplied(id: String, at now: Date) throws {
        try locked { try db.query("UPDATE messages SET replied_at = COALESCE(replied_at, ?) WHERE id = ?", [SQLValue(now), .text(id)]) }
    }

    public func flagStale(id: String) throws {
        try locked { try db.query("UPDATE messages SET stale_flagged = 1 WHERE id = ?", [.text(id)]) }
    }

    /// 两个信箱之间（两个方向合计）某时刻以来的信件数
    public func countMessages(between a: String, and b: String, since: Date) throws -> Int {
        try locked {
            try db.query("""
            SELECT COUNT(*) AS n FROM messages WHERE created_at >= ? AND
                ((from_mailbox = ? AND to_mailbox = ?) OR (from_mailbox = ? AND to_mailbox = ?))
            """, [SQLValue(since), .text(a), .text(b), .text(b), .text(a)])[0].int("n") ?? 0
        }
    }

    public func countMessages(since: Date) throws -> Int {
        try locked { try db.query("SELECT COUNT(*) AS n FROM messages WHERE created_at >= ?", [SQLValue(since)])[0].int("n") ?? 0 }
    }

    public func recentMessages(limit: Int) throws -> [MessageRow] {
        try locked { try messageRows("ORDER BY created_at DESC, id DESC LIMIT ?", [.int(limit)]) }
    }

    /// 需要回复、还没等到回信、还没标过“可能卡住”、发出早于某时刻的信
    public func awaitingReply(createdBefore: Date) throws -> [MessageRow] {
        try locked {
            try messageRows("""
            WHERE needs_reply = 1 AND replied_at IS NULL AND stale_flagged = 0 AND status != 'failed' AND created_at < ?
            ORDER BY created_at
            """, [SQLValue(createdBefore)])
        }
    }

    /// 某时刻以来收过信、需要回复而还没回信的 Codex 信箱（ChatGPT 重启提醒用）
    public func codexMailboxesAwaitingReply(since: Date) throws -> [String] {
        try locked {
            try db.query("""
            SELECT DISTINCT to_mailbox FROM messages WHERE to_platform = 'codex' AND created_at >= ?
                AND needs_reply = 1 AND replied_at IS NULL AND status != 'failed' ORDER BY to_mailbox
            """, [SQLValue(since)]).compactMap { $0.string("to_mailbox") }
        }
    }

    private func messageRows(_ tail: String, _ params: [SQLValue]) throws -> [MessageRow] {
        try db.query("SELECT * FROM messages " + tail, params).map { r in
            MessageRow(
                id: r.string("id")!, chainID: r.string("chain_id")!, hop: r.int("hop")!, fromSession: r.int("from_session")!,
                toSession: r.int("to_session")!, fromMailbox: r.string("from_mailbox")!, toMailbox: r.string("to_mailbox")!,
                fromPlatform: Platform(rawValue: r.string("from_platform")!)!, toPlatform: Platform(rawValue: r.string("to_platform")!)!,
                fromProject: r.string("from_project")!, replyTo: r.string("reply_to"), subject: r.string("subject"),
                body: r.string("body")!, needsReply: r.bool("needs_reply"),
                status: MessageStatus(rawValue: r.string("status")!) ?? .failed, queueRef: r.string("queue_ref"),
                error: r.string("error"), createdAt: r.date("created_at")!, deliveredAt: r.date("delivered_at"),
                readAt: r.date("read_at"), repliedAt: r.date("replied_at"), staleFlagged: r.bool("stale_flagged"),
                requestedDelivery: r.string("requested_delivery").flatMap(DeliveryMode.init(rawValue:)) ?? .queue,
                actualDelivery: r.string("actual_delivery").flatMap(DeliveryMode.init(rawValue:)),
                codexTurnID: r.string("codex_turn_id"), codexHookEvent: r.string("codex_hook_event"))
        }
    }

    // MARK: 事件

    /// 记一条事件。摘要里不要放信件正文。
    public func addEvent(kind: String, summary: String, at now: Date) throws {
        try locked { try db.query("INSERT INTO events (time, kind, summary) VALUES (?, ?, ?)", [SQLValue(now), .text(kind), .text(summary)]) }
    }

    public func events(limit: Int) throws -> [EventRow] {
        try locked {
            try db.query("SELECT * FROM events ORDER BY id DESC LIMIT ?", [.int(limit)]).map {
                EventRow(id: $0.int("id")!, time: $0.date("time")!, kind: $0.string("kind")!, summary: $0.string("summary")!)
            }
        }
    }

    // MARK: 设置与清理

    public var isPaused: Bool {
        get { (try? locked { try metaValue("paused") }) == "1" }
    }

    public func setPaused(_ paused: Bool) throws {
        try locked { try setMeta("paused", paused ? "1" : "0") }
    }

    /// 删除保留期之前的信件和事件，返回删掉的信件数
    @discardableResult
    public func purge(before cutoff: Date) throws -> Int {
        try locked {
            try db.transaction {
                try db.query("DELETE FROM messages WHERE created_at < ?", [SQLValue(cutoff)])
                let n = db.changes
                try db.query("DELETE FROM events WHERE time < ?", [SQLValue(cutoff)])
                try db.query("DELETE FROM sessions WHERE status IN ('replaced', 'disabled') AND last_active_at < ?", [SQLValue(cutoff)])
                return n
            }
        }
    }

    func metaValue(_ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.string("value")
    }

    func setMeta(_ key: String, _ value: String) throws {
        try db.query("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                     [.text(key), .text(value)])
    }
}

extension SessionRow: Identifiable {}
extension MessageRow: Identifiable {}

import Foundation
import Testing
@testable import RelayCore

@Suite("信件库")
struct StoreTests {
    let dir: TempDir
    let store: Store

    init() throws {
        dir = try TempDir()
        store = try Store(path: dir.path + "/relay.sqlite")
    }

    func session(_ mailbox: String, _ n: Int, _ platform: Platform = .claude, status: SessionStatus = .active) throws -> SessionRow {
        try store.insertSession(platform: platform, sessionID: sampleID(n), hostSessionID: nil, project: "项目甲", group: "组甲",
                                mailbox: mailbox, recordCwd: "/private/tmp/甲", identitySource: .env, status: status, at: Date())
    }

    @Test("数据库文件权限 0600")
    func permissions() throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path + "/relay.sqlite")
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test("会话：同一平台同一编号再登记会覆盖原记录")
    func sessions() throws {
        let a = try session("claude-1", 1)
        #expect(try store.session(platform: .claude, sessionID: sampleID(1)) == a)
        #expect(try store.activeSession(mailbox: "claude-1")?.id == a.id)
        let again = try session("claude-2", 1)
        #expect(again.id == a.id)
        #expect(again.mailbox == "claude-2")
        #expect(try store.session(platform: .codex, sessionID: sampleID(1)) == nil)
    }

    @Test("信件编号按天递增，新来回链全局递增，回信沿用来回链")
    func messageIDs() throws {
        let a = try session("claude-1", 1), b = try session("codex-a", 2, .codex)
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let day1 = Date(timeIntervalSince1970: 1_794_500_000)
        let m1 = try store.insertMessage(.init(chainID: nil, hop: 1, from: a, to: b, replyTo: nil, subject: nil, body: "一",
                                               needsReply: true, status: .queued, createdAt: day1), timeZone: tz)
        let m2 = try store.insertMessage(.init(chainID: m1.chainID, hop: 2, from: b, to: a, replyTo: m1.id, subject: nil, body: "二",
                                               needsReply: true, status: .pending, createdAt: day1.addingTimeInterval(1)), timeZone: tz)
        let m3 = try store.insertMessage(.init(chainID: nil, hop: 1, from: a, to: b, replyTo: nil, subject: nil, body: "三",
                                               needsReply: false, status: .queued, createdAt: day1.addingTimeInterval(86_400)), timeZone: tz)
        #expect(m1.id == "M-20261113-0001")
        #expect(m2.id == "M-20261113-0002")
        #expect(m3.id == "M-20261114-0001")
        #expect(m1.chainID == "C-0001")
        #expect(m2.chainID == "C-0001")
        #expect(m3.chainID == "C-0002")
    }

    @Test("未读、已读、计数")
    func unreadAndCounts() throws {
        let a = try session("claude-1", 1), b = try session("codex-a", 2, .codex), c = try session("claude-3", 3)
        let now = Date()
        for i in 0..<3 {
            _ = try store.insertMessage(.init(chainID: nil, hop: 1, from: b, to: a, replyTo: nil, subject: nil, body: "\(i)",
                                              needsReply: true, status: .pending, createdAt: now))
        }
        _ = try store.insertMessage(.init(chainID: nil, hop: 1, from: c, to: b, replyTo: nil, subject: nil, body: "x",
                                          needsReply: true, status: .queued, createdAt: now))
        #expect(try store.unreadCount(toSession: a.id) == 3)
        let unread = try store.unread(toSession: a.id)
        try store.markRead(unread.prefix(2).map(\.id), at: now)
        #expect(try store.unreadCount(toSession: a.id) == 1)
        #expect(try store.countMessages(between: "claude-1", and: "codex-a", since: now.addingTimeInterval(-60)) == 3)
        #expect(try store.countMessages(between: "codex-a", and: "claude-1", since: now.addingTimeInterval(-60)) == 3)
        #expect(try store.countMessages(since: now.addingTimeInterval(-60)) == 4)
        #expect(try store.countMessages(since: now.addingTimeInterval(60)) == 0)
    }

    @Test("交接：旧会话标为已被接手，未读信改寄给新会话")
    func handoff() throws {
        let old = try session("claude-1", 1), sender = try session("codex-a", 2, .codex)
        let m = try store.insertMessage(.init(chainID: nil, hop: 1, from: sender, to: old, replyTo: nil, subject: nil, body: "x",
                                              needsReply: true, status: .pending, createdAt: Date()))
        let new = try session("claude-1", 3, status: .pendingHandoff)
        #expect(try store.pendingHandoff(mailbox: "claude-1")?.id == new.id)
        try store.confirmHandoff(from: old.id, to: new.id, at: Date())
        #expect(try store.activeSession(mailbox: "claude-1")?.id == new.id)
        #expect(try store.session(id: old.id)?.status == .replaced)
        #expect(try store.message(id: m.id)?.toSession == new.id)
    }

    @Test("暂停开关、事件、30 天清理")
    func pauseEventsPurge() throws {
        #expect(!store.isPaused)
        try store.setPaused(true)
        #expect(store.isPaused)
        let a = try session("claude-1", 1), b = try session("codex-a", 2, .codex)
        let old = Date().addingTimeInterval(-31 * 86_400)
        _ = try store.insertMessage(.init(chainID: nil, hop: 1, from: a, to: b, replyTo: nil, subject: nil, body: "旧",
                                          needsReply: false, status: .queued, createdAt: old))
        _ = try store.insertMessage(.init(chainID: nil, hop: 1, from: a, to: b, replyTo: nil, subject: nil, body: "新",
                                          needsReply: false, status: .queued, createdAt: Date()))
        try store.addEvent(kind: "测试", summary: "旧事件", at: old)
        try store.addEvent(kind: "测试", summary: "新事件", at: Date())
        #expect(try store.purge(before: Date().addingTimeInterval(-30 * 86_400)) == 1)
        #expect(try store.recentMessages(limit: 10).map(\.body) == ["新"])
        #expect(try store.events(limit: 10).map(\.summary) == ["新事件"])
    }

    @Test("等回信和 Codex 重启提醒的查询")
    func awaiting() throws {
        let a = try session("claude-1", 1), b = try session("codex-a", 2, .codex)
        let t0 = Date().addingTimeInterval(-1_000)
        let m = try store.insertMessage(.init(chainID: nil, hop: 1, from: a, to: b, replyTo: nil, subject: nil, body: "x",
                                              needsReply: true, status: .queued, createdAt: t0))
        #expect(try store.awaitingReply(createdBefore: Date()).map(\.id) == [m.id])
        #expect(try store.codexMailboxesAwaitingReply(since: t0.addingTimeInterval(-1)) == ["codex-a"])
        try store.markReplied(id: m.id, at: Date())
        #expect(try store.awaitingReply(createdBefore: Date()).isEmpty)
        #expect(try store.codexMailboxesAwaitingReply(since: t0.addingTimeInterval(-1)).isEmpty)
    }
}

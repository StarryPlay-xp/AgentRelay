import Foundation
import Testing
@testable import RelayCore

@Suite("数据库里的登记表和设置")
struct ProjectRegistryTests {
    let dir: TempDir
    let store: Store

    init() throws {
        dir = try TempDir()
        store = try Store(path: dir.path + "/relay.sqlite")
    }

    @Test("分组：新建、重名、改名、删除后项目变为未分组")
    func groups() throws {
        let a = try store.addGroup(" 组甲 ")
        #expect(a.name == "组甲")
        #expect(throws: RelayError.self) { try store.addGroup("组甲") }
        #expect(throws: RelayError.self) { try store.addGroup("  ") }
        let b = try store.addGroup("组乙")
        #expect(throws: RelayError.self) { try store.renameGroup(id: b.id, to: "组甲") }
        try store.renameGroup(id: b.id, to: "组丙")
        #expect(try store.groups().map(\.name) == ["组甲", "组丙"])
        let p = try store.addProject(NewProject(platform: .codex, name: "项目", source: .manual, groupID: a.id, mainPaths: [dir.path]))
        #expect(p.groupName == "组甲")
        try store.deleteGroup(id: a.id)
        let after = try #require(try store.projects().first)
        #expect(after.groupID == nil)
        #expect(try store.registry().projects.first?.isUsable == false)
    }

    @Test("项目：目录规范化、去重，附加目录不和主目录重复；各种不合法输入报错")
    func addProject() throws {
        let g = try store.addGroup("组")
        let p = try store.addProject(NewProject(
            platform: .claude, name: "项目甲", source: .claudeConfig, groupID: g.id,
            mainPaths: ["~/甲/", "/tmp/ar-x/../ar-y"], extraPaths: ["~/甲", "/tmp/副本"], includeWorktrees: true),
            userHome: dir.path)
        #expect(p.mainPaths == [dir.path + "/甲", "/private/tmp/ar-y"])
        #expect(p.extraPaths == ["/private/tmp/副本"])
        #expect(p.includeWorktrees)
        #expect(p.source == .claudeConfig)
        let bad: [NewProject] = [
            NewProject(platform: .codex, name: "项目甲", source: .manual, mainPaths: ["/a"]),
            NewProject(platform: .codex, name: " ", source: .manual, mainPaths: ["/a"]),
            NewProject(platform: .codex, name: "空", source: .manual, mainPaths: [" "]),
            NewProject(platform: .codex, name: "相对", source: .manual, mainPaths: ["相对/路径"]),
            NewProject(platform: .codex, name: "组不存在", source: .manual, groupID: 999, mainPaths: ["/a"]),
        ]
        for b in bad { #expect(throws: RelayError.self) { try store.addProject(b, userHome: dir.path) } }
        #expect(try store.projects().count == 1)
    }

    @Test("项目：改名、换分组、启用停用、Git 工作副本开关、附加目录、删除")
    func updateProject() throws {
        let g1 = try store.addGroup("组一"), g2 = try store.addGroup("组二")
        let p = try store.addProject(NewProject(platform: .codex, name: "甲", source: .manual, groupID: g1.id, mainPaths: ["/private/tmp/甲"]))
        _ = try store.addProject(NewProject(platform: .codex, name: "乙", source: .manual, mainPaths: ["/private/tmp/乙"]))
        #expect(throws: RelayError.self) { try store.renameProject(id: p.id, to: "乙") }
        try store.renameProject(id: p.id, to: "甲改")
        try store.setProjectGroup(id: p.id, groupID: g2.id)
        try store.setProjectEnabled(id: p.id, false)
        try store.setProjectIncludeWorktrees(id: p.id, true)
        try store.setExtraPaths(id: p.id, ["/private/tmp/副本", "/private/tmp/甲"])
        let q = try #require(try store.projects().first { $0.id == p.id })
        #expect(q.name == "甲改")
        #expect(q.groupName == "组二")
        #expect(!q.enabled)
        #expect(q.includeWorktrees)
        #expect(q.extraPaths == ["/private/tmp/副本"])
        #expect(throws: RelayError.self) { try store.setProjectGroup(id: p.id, groupID: 999) }
        try store.deleteProject(id: p.id)
        #expect(try store.projects().map(\.name) == ["乙"])
    }

    @Test("生成登记表：分组、项目、能不能用、按目录匹配、codex 路径")
    func registry() throws {
        let g = try store.addGroup("组")
        try store.addProject(NewProject(platform: .codex, name: "甲", source: .manual, groupID: g.id, mainPaths: ["/private/tmp/甲"],
                                        extraPaths: ["/private/tmp/副本"]))
        try store.addProject(NewProject(platform: .claude, name: "乙", source: .manual, mainPaths: ["/private/tmp/甲"]))
        try store.setCodexPath("/Applications/示例/codex")
        let r = try store.registry()
        #expect(r.groups == ["组"])
        #expect(r.project(for: .codex, containing: "/private/tmp/副本/x")?.name == "甲")
        #expect(r.project(for: .claude, containing: "/private/tmp/甲")?.isUsable == false)
        #expect(r.codexPath == "/Applications/示例/codex")
        try store.setCodexPath(nil)
        #expect(store.codexPath() == nil)
        let source = DatabaseRegistry(store: store)
        #expect(source.snapshot().registry == r.withoutCodexPath)
        #expect(source.snapshot().error == nil)
    }

    @Test("上限：默认值、保存后读回、不合法的值被拒绝")
    func limits() throws {
        #expect(store.limits() == Limits())
        var l = Limits()
        l.pairPerHour = 5
        l.retentionDays = 7
        try store.setLimits(l)
        #expect(store.limits() == l)
        l.hopLimit = 0
        #expect(throws: RelayError.self) { try store.setLimits(l) }
    }
}

extension Registry {
    var withoutCodexPath: Registry { Registry(groups: groups, projects: projects, codexPath: nil) }
}

@Suite("界面上的会话管理和待处理")
struct ManagementTests {
    @Test("中转服务改用数据库登记表，原有流程照常；改分组、停用项目、改上限立即生效")
    func databaseRegistry() throws {
        let h = try Harness(database: true)
        h.registerAll()
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "你好"))
        let store = h.service.store
        var l = store.limits()
        l.pairPerHour = 1
        try store.setLimits(l)
        h.fails(h.codex(1), .send, WireArgs(to: "claude-1", body: "第二封"), .rateLimit)
        let projectB = try #require(try store.projects().first { $0.name == "项目乙" })
        try store.setProjectEnabled(id: projectB.id, false)
        h.fails(h.codex(2), .status, WireArgs(), .projectNotRegistered)
        let claude = try #require(try store.projects().first { $0.name == "项目甲-Claude" })
        let other = try #require(try store.groups().first { $0.name == "组乙" })
        try store.setProjectGroup(id: claude.id, groupID: other.id)
        h.fails(h.codex(1), .send, WireArgs(to: "claude-1", body: "x"), .notSameGroup)
    }

    @Test("改信箱名：全局唯一；Claude 的未读标记跟着搬；对方联系人里显示新名字")
    func rename() throws {
        let h = try Harness()
        h.registerAll()
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "未读"))
        let s = try #require(try h.service.store.session(platform: .claude, sessionID: sampleID(11)))
        #expect(throws: RelayError.self) { try h.service.renameMailbox(session: s.id, to: "codex-a") }
        #expect(throws: RelayError.self) { try h.service.renameMailbox(session: s.id, to: "不合规") }
        try h.service.renameMailbox(session: s.id, to: "claude-new")
        let box = ClaudeMailbox(paths: h.paths)
        #expect(box.unreadMarker(mailbox: "claude-1") == nil)
        #expect(box.unreadMarker(mailbox: "claude-new") == 1)
        #expect(h.ok(h.codex(1), .contacts).contacts?.map(\.mailbox).contains("claude-new") == true)
        #expect(h.ok(h.claude(11), .inbox).waitCommand?.contains("--mailbox claude-new") == true)
    }

    @Test("停用会话后它的调用被拒绝；重新启用恢复；名字被占用时不能启用")
    func disable() throws {
        let h = try Harness()
        h.registerAll()
        let s = try #require(try h.service.store.session(platform: .codex, sessionID: sampleID(1)))
        try h.service.setSessionEnabled(id: s.id, false)
        h.fails(h.codex(1), .status, WireArgs(), .sessionNotRegistered)
        h.fails(h.claude(11), .send, WireArgs(to: "codex-a", body: "x"), .recipientNotFound)
        try h.service.setSessionEnabled(id: s.id, true)
        _ = h.ok(h.codex(1), .status)
        try h.service.setSessionEnabled(id: s.id, false)
        _ = h.ok(h.codex(2), .register, WireArgs(mailbox: "x"))
        let b = try #require(try h.service.store.session(platform: .codex, sessionID: sampleID(2)))
        try h.service.renameMailbox(session: b.id, to: "codex-a")
        #expect(throws: RelayError.self) { try h.service.setSessionEnabled(id: s.id, true) }
    }

    @Test("待处理：交接可以确认或拒绝；提醒事件看过后标为已处理")
    func attention() throws {
        let h = try Harness()
        h.registerAll()
        h.fails(h.claude(12), .register, WireArgs(mailbox: "claude-1"), .mailboxTaken)
        let token = "gh" + "p_" + String(repeating: "a", count: 36)
        h.fails(h.codex(1), .send, WireArgs(to: "claude-1", body: token), .secretSuspected)
        var items = try h.service.attentionItems()
        #expect(items.contains { $0.kind == .handoff(mailbox: "claude-1") })
        let event = try #require(items.first { $0.title == "拦截" })
        #expect(!event.detail.contains(token))
        try h.service.rejectHandoff(mailbox: "claude-1")
        _ = h.ok(h.claude(12), .register, WireArgs(mailbox: "claude-2"))
        if case .event(let id) = event.kind { try h.service.store.acknowledgeEvent(id: id) }
        items = try h.service.attentionItems()
        #expect(items.isEmpty, "\(items)")
        #expect(try h.service.store.countMessagesToday() == 0)
        _ = h.ok(h.codex(1), .send, WireArgs(to: "claude-1", body: "今天的信"))
        #expect(try h.service.store.countMessagesToday() == 1)
    }
}

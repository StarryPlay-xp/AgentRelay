import Foundation
import Testing
@testable import RelayCore

@Suite("读取两边已有项目、识别 Git 工作副本")
struct DiscoveryTests {
    let t: TempDir
    let d: ProjectDiscovery

    init() throws {
        t = try TempDir()
        d = ProjectDiscovery(codexHome: t.path + "/codex", claudeConfigFile: t.path + "/claude.json", claudeProjects: t.path + "/claude/projects")
        for dir in ["codex", "claude/projects", "甲", "乙", "丙"] {
            try FileManager.default.createDirectory(atPath: t.path + "/" + dir, withIntermediateDirectories: true)
        }
    }

    /// 合成一个和 Codex 项目表结构相同的数据库
    func makeCodexDB(version: Int = 5, broken: Bool = false) throws {
        let db = try SQLiteDatabase(path: t.path + "/codex/state_\(version).sqlite")
        if broken {
            try db.execute("CREATE TABLE projects (id TEXT PRIMARY KEY, title TEXT)")
            return
        }
        try db.execute("""
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, metadata TEXT NOT NULL DEFAULT '{}', position INTEGER NOT NULL,
                               created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
        CREATE TABLE project_roots (project_id TEXT NOT NULL, position INTEGER NOT NULL, path TEXT NOT NULL, PRIMARY KEY (project_id, position));
        INSERT INTO projects VALUES ('p2', '项目乙', '{"不应读取":true}', 2, 0, 0);
        INSERT INTO projects VALUES ('p1', '项目甲', '{}', 1, 0, 0);
        INSERT INTO project_roots VALUES ('p1', 0, '\(t.path)/甲');
        INSERT INTO project_roots VALUES ('p1', 1, '\(t.path)/甲/');
        INSERT INTO project_roots VALUES ('p2', 0, '\(t.path)/乙');
        """)
    }

    func writeConfigToml() throws {
        try """
        model = "示例"
        [projects."\(t.path)/甲"]
        trust_level = "trusted"
        [projects."\(t.path)/丙"]
        trust_level = "trusted"
        [projects."/private/tmp/带\\"引号"]
        trust_level = "trusted"
        [mcp_servers.示例]
        command = "x"
        """.write(toFile: t.path + "/codex/config.toml", atomically: true, encoding: .utf8)
    }

    @Test("Codex：项目表按顺序列出，一个项目多个目录；再补上项目表里没有的信任目录")
    func codexTable() throws {
        try makeCodexDB()
        try writeConfigToml()
        let r = d.codex()
        #expect(r.notes.isEmpty)
        #expect(r.projects.map(\.name) == ["项目甲", "项目乙", "丙", "带\"引号"])
        #expect(r.projects[0].paths == [t.path + "/甲"])
        #expect(r.projects[0].source == .codexProjects)
        #expect(r.projects[2].source == .codexTrusted)
        #expect(r.projects[2].exists)
        #expect(r.projects[3].paths == ["/private/tmp/带\"引号"])
        #expect(!r.projects[3].exists)
    }

    @Test("Codex：项目表读不了（没有或结构变了）就退到信任目录，并说明原因")
    func codexFallback() throws {
        try writeConfigToml()
        #expect(d.codex().notes.count == 1)
        try makeCodexDB(version: 6, broken: true)
        let r = d.codex()
        #expect(r.notes.count == 1)
        #expect(r.projects.allSatisfy { $0.source == .codexTrusted })
        #expect(r.projects.count == 3)
    }

    @Test("Codex：只读打开，不改动对方的数据库文件")
    func codexReadOnly() throws {
        try makeCodexDB()
        let file = t.path + "/codex/state_5.sqlite"
        let before = try Data(contentsOf: URL(fileURLWithPath: file))
        _ = d.codex()
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == before)
    }

    @Test("Claude：取 ~/.claude.json 里 projects 的键；再补上会话记录里出现、配置里没有的目录")
    func claude() throws {
        try #"""
        {"oauthAccount": {"emailAddress": "someone@example.com"}, "numStartups": 3,
         "projects": {"\#(t.path)/甲": {"allowedTools": []}, "\#(t.path)/乙/": {}}}
        """#.write(toFile: t.path + "/claude.json", atomically: true, encoding: .utf8)
        let rec = t.path + "/claude/projects/-编码"
        try FileManager.default.createDirectory(atPath: rec, withIntermediateDirectories: true)
        try #"{"type":"summary"}"#.appending("\n").appending(#"{"cwd":"\#(t.path)/丙","message":"会话内容"}"#)
            .write(toFile: rec + "/\(sampleID(1)).jsonl", atomically: true, encoding: .utf8)
        let r = d.claude()
        #expect(r.notes.isEmpty)
        #expect(Set(r.projects.filter { $0.source == .claudeConfig }.flatMap(\.paths)) == [t.path + "/甲", t.path + "/乙"])
        #expect(r.projects.last?.paths == [t.path + "/丙"])
        #expect(r.projects.last?.source == .claudeRecords)
        #expect(r.projects.count == 3)
    }

    @Test("Claude：配置读不了时只列会话记录里的目录，并说明原因")
    func claudeFallback() throws {
        try "不是 JSON".write(toFile: t.path + "/claude.json", atomically: true, encoding: .utf8)
        let r = d.claude()
        #expect(r.notes.count == 1)
        #expect(r.projects.isEmpty)
    }

    @Test("Git：主目录和工作副本得到同一个共用目录；不在仓库里返回 nil")
    func gitCommonDir() throws {
        let main = t.path + "/仓库"
        let wt = t.path + "/副本"
        try FileManager.default.createDirectory(atPath: main + "/.git/worktrees/副本", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: main + "/子目录", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: wt + "/深层", withIntermediateDirectories: true)
        try "gitdir: \(main)/.git/worktrees/副本\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        try "../..\n".write(toFile: main + "/.git/worktrees/副本/commondir", atomically: true, encoding: .utf8)
        let common = main + "/.git"
        #expect(GitRepo.commonDir(containing: main) == common)
        #expect(GitRepo.commonDir(containing: main + "/子目录") == common)
        #expect(GitRepo.commonDir(containing: wt + "/深层") == common)
        #expect(GitRepo.commonDir(containing: t.path + "/甲") == nil)
    }

    @Test("登记表：勾选了“包含 Git 工作副本”的项目能认出副本里的会话，没勾选的不认")
    func worktreeMatching() throws {
        let main = t.path + "/仓库"
        let wt = t.path + "/副本"
        try FileManager.default.createDirectory(atPath: main + "/.git/worktrees/wt", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "gitdir: ../仓库/.git/worktrees/wt\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        try "../..\n".write(toFile: main + "/.git/worktrees/wt/commondir", atomically: true, encoding: .utf8)
        let store = try Store(path: t.path + "/relay.sqlite")
        let g = try store.addGroup("组")
        let p = try store.addProject(NewProject(platform: .claude, name: "仓库", source: .manual, groupID: g.id, mainPaths: [main]))
        #expect(try store.registry().project(for: .claude, containing: wt) == nil)
        try store.setProjectIncludeWorktrees(id: p.id, true)
        #expect(try store.registry().project(for: .claude, containing: wt)?.name == "仓库")
        #expect(try store.registry().project(for: .codex, containing: wt) == nil)
    }
}

import Foundation
import Testing
@testable import RelayCore

@Suite("位置")
struct PathsTests {
    @Test("默认位置")
    func defaults() {
        let p = RelayPaths.resolve(environment: [:], userHome: "/Users/<用户名>")
        #expect(p.home == "/Users/<用户名>/.agentrelay")
        #expect(p.socket == "/Users/<用户名>/.agentrelay/run/relay.sock")
        #expect(p.data == "/Users/<用户名>/Library/Application Support/AgentRelay")
        #expect(p.database.hasSuffix("/AgentRelay/relay.sqlite"))
        #expect(p.logs == "/Users/<用户名>/Library/Logs/AgentRelay")
        #expect(p.mailboxMarker("claude-1") == "/Users/<用户名>/.agentrelay/run/mailboxes/claude-1/new")
    }

    @Test("AGENTRELAY_HOME 把所有东西放到一个目录下，支持 ~")
    func customHome() {
        let p = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": "~/.agentrelay-dev"], userHome: "/Users/<用户名>")
        #expect(p.home == "/Users/<用户名>/.agentrelay-dev")
        #expect(p.data == "/Users/<用户名>/.agentrelay-dev/data")
        #expect(p.logs == "/Users/<用户名>/.agentrelay-dev/logs")
    }

    @Test("空的 AGENTRELAY_HOME 当作没设")
    func emptyHome() {
        let p = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": ""], userHome: "/Users/<用户名>")
        #expect(p.home == "/Users/<用户名>/.agentrelay")
    }

    @Test("Codex、Claude 数据位置跟随 CODEX_HOME、CLAUDE_CONFIG_DIR")
    func external() {
        let d = ExternalPaths.resolve(environment: [:], userHome: "/Users/<用户名>")
        #expect(d.codexSessions == "/Users/<用户名>/.codex/sessions")
        #expect(d.claudeProjects == "/Users/<用户名>/.claude/projects")
        let c = ExternalPaths.resolve(environment: ["CODEX_HOME": "/tmp/cx", "CLAUDE_CONFIG_DIR": "/tmp/cl"], userHome: "/Users/<用户名>")
        #expect(c.codexSessions == "/tmp/cx/sessions")
        #expect(c.claudeProjects == "/tmp/cl/projects")
    }

    @Test("prepare 建目录并设 0700；套接字路径太长时报错")
    func prepare() throws {
        let root = try TempDir()
        let p = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": root.path + "/h"])
        try p.prepare()
        for dir in [p.home, p.run, p.mailboxes, p.data, p.logs] {
            let attrs = try FileManager.default.attributesOfItem(atPath: dir)
            #expect((attrs[.posixPermissions] as? Int) == 0o700)
        }
        let long = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": root.path + "/" + String(repeating: "x", count: 120)])
        #expect(throws: RelayError.self) { try long.prepare() }
    }

    @Test("原子写入的文件权限是 0600")
    func atomicWrite() throws {
        let root = try TempDir()
        let f = root.path + "/a.txt"
        try FileSystem.writeAtomically(Data("1".utf8), to: f)
        try FileSystem.writeAtomically(Data("2".utf8), to: f)
        #expect(try String(contentsOfFile: f, encoding: .utf8) == "2")
        let attrs = try FileManager.default.attributesOfItem(atPath: f)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }
}

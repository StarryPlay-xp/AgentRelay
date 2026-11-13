import CryptoKit
import Foundation
import RelayCore
import Testing

/// 接入向导用到的真实进程：relay-mcp 握手（默认就跑）；真的 codex、claude 在临时配置目录里装上再卸载（手动开启）。
@Suite("集成测试：接入向导", .serialized)
struct SetupTests {
    /// 临时目录里的数据目录，`bin/relay-mcp` 链接到构建出的程序（应用启动时建的链接也是这样）
    private func relayHome() throws -> (root: String, paths: RelayPaths, store: Store) {
        let root = "/tmp/ar-setup/" + String(UUID().uuidString.prefix(8)).lowercased()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let paths = RelayPaths.resolve(environment: ["AGENTRELAY_HOME": root + "/relay"])
        try paths.prepare()
        try FileManager.default.createSymbolicLink(atPath: paths.bin + "/relay-mcp", withDestinationPath: try binary("relay-mcp"))
        return (root, paths, try Store(path: paths.database))
    }

    @Test("核对：真的 relay-mcp 经 bin 链接拉起，完成 MCP 握手")
    func handshake() throws {
        let (root, paths, store) = try relayHome()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let i = Integrations(paths: paths, store: store, codexExecutable: { nil }, claudeExecutable: { nil })
        let r = i.selfTest()
        #expect(r.ok, "\(r.detail)")
        unlink(paths.bin + "/relay-mcp")
        #expect(!i.selfTest().ok)
    }

    /// 真实配置的指纹：只用来核对测试没碰它们，不显示内容
    private func fingerprint(_ path: String) -> String {
        guard let d = FileManager.default.contents(atPath: path) else { return "（没有这个文件）" }
        return SHA256.hash(data: d).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func realClaudeServerNames() -> [String] {
        let file = RelayPaths.userHome() + "/.claude.json"
        let obj = FileManager.default.contents(atPath: file).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return ((obj?["mcpServers"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    @Test("真实命令、临时目录：codex、claude 装上、核对、卸载后恢复原样（手动开启：AGENTRELAY_REAL_CLI_TEST=1）",
          .enabled(if: ProcessInfo.processInfo.environment["AGENTRELAY_REAL_CLI_TEST"] == "1"))
    func realCommands() throws {
        let codex = CodexCLI.chatGPTDefault
        let claude = try #require(ClaudeCLI.locate(configuredPath: nil), "找不到 claude 程序")
        try #require(FileManager.default.isExecutableFile(atPath: codex), "找不到 ChatGPT 自带的 codex")
        let (root, paths, store) = try relayHome()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let codexHome = root + "/codex", claudeDir = root + "/claude"
        for d in [codexHome, claudeDir] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let original = Data("model = \"示例\"\n\n[projects.\"/示例\"]\ntrust_level = \"trusted\"\n".utf8)
        try original.write(to: URL(fileURLWithPath: codexHome + "/config.toml"))

        let realCodex = RelayPaths.userHome() + "/.codex/config.toml"
        let codexBefore = fingerprint(realCodex)
        let claudeBefore = realClaudeServerNames()

        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome
        env["CLAUDE_CONFIG_DIR"] = claudeDir
        let i = Integrations(paths: paths, store: store, environment: env, codexExecutable: { codex }, claudeExecutable: { claude })

        // Codex：装上 → 核对 → 卸载后和装前一字不差
        #expect(i.status(.codex).state == .notInstalled)
        let ic = i.install(.codex)
        #expect(ic.ok, "\(ic.lines)")
        let vc = i.verify(.codex)
        #expect(vc.ok, "\(vc.lines)")
        let uc = i.uninstall(.codex)
        #expect(uc.ok, "\(uc.lines)")
        #expect(FileManager.default.contents(atPath: codexHome + "/config.toml") == original)

        // Claude：装上 → 核对（含官方连通检查）→ 卸载后 mcpServers 回到空
        #expect(i.status(.claude).state == .notInstalled)
        let il = i.install(.claude)
        #expect(il.ok, "\(il.lines)")
        let vl = i.verify(.claude)
        #expect(vl.ok, "\(vl.lines)")
        let ul = i.uninstall(.claude)
        #expect(ul.ok, "\(ul.lines)")
        let obj = FileManager.default.contents(atPath: claudeDir + "/.claude.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect((obj?["mcpServers"] as? [String: Any])?.isEmpty == true)

        // 真实配置一点没动
        #expect(fingerprint(realCodex) == codexBefore, "真实的 config.toml 被改了")
        #expect(realClaudeServerNames() == claudeBefore, "真实的 ~/.claude.json 全局服务被改了")
    }
}

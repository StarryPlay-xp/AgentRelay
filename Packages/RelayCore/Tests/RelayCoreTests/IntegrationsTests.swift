import Foundation
import Testing
@testable import RelayCore

/// 假的 codex、claude 命令：在临时目录里按真实命令的行为改配置（2026-11-13 用真实命令在临时目录里实测过）。
/// - codex：配置在 `$CODEX_HOME/config.toml`；`mcp add` 会把整个文件按行排序（模拟官方命令重新排版，F19）；
///   `mcp get` 找不到时退出码 1，`mcp remove` 找不到时退出码 0
/// - claude：配置在 `$CLAUDE_CONFIG_DIR/.claude.json` 顶层 `mcpServers`；`mcp remove` 找不到时退出码 1；
///   `mcp get` 的连通检查看命令能不能执行
/// - relay-mcp：程序文件存在且可执行就回握手结果
final class FakeCLI: CommandRunning, @unchecked Sendable {
    /// 假程序的路径：临时目录里真实存在的可执行文件（接入向导会先检查程序文件能不能执行），内容不会被运行
    let codex: String
    let claude: String

    init(dir: String) throws {
        codex = dir + "/codex"
        claude = dir + "/claude"
        for f in [codex, claude] {
            try "#!/bin/sh\nexit 99\n".write(toFile: f, atomically: true, encoding: .utf8)
            chmod(f, 0o755)
        }
    }

    private let lock = NSLock()
    private(set) var calls: [(exe: String, args: [String])] = []
    /// 按“程序名 子命令”预设失败，例如 "codex add"
    var failures: [String: CommandResult] = [:]

    func run(_ executable: String, _ arguments: [String], environment: [String: String],
             currentDirectory: String?, input: Data?, timeout: TimeInterval) -> CommandResult {
        lock.lock()
        calls.append((executable, arguments))
        lock.unlock()
        let name = (executable as NSString).lastPathComponent
        if name == "relay-mcp" {
            return FileManager.default.isExecutableFile(atPath: executable)
                ? CommandResult(status: 0, stdout: #"{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"agentrelay"}}}"#)
                : CommandResult(status: 127, stderr: "启动失败")
        }
        guard arguments.count >= 3, arguments[0] == "mcp" else { return CommandResult(status: 2, stderr: "用法不对") }
        if let f = failures["\(name) \(arguments[1])"] { return f }
        switch executable {
        case codex: return codexRun(Array(arguments.dropFirst()), home: environment["CODEX_HOME"]!)
        case claude: return claudeRun(Array(arguments.dropFirst()), dir: environment["CLAUDE_CONFIG_DIR"]!)
        default: return CommandResult(status: 127, stderr: "没有这个程序")
        }
    }

    func calls(of exe: String) -> [[String]] { lock.lock(); defer { lock.unlock() }; return calls.filter { $0.exe == exe }.map(\.args) }

    // MARK: codex：服务写成一行 `mcp <名字> <命令> <K=V,...>`，其他行原样保留，排版时整体排序

    private func codexRun(_ a: [String], home: String) -> CommandResult {
        let file = home + "/config.toml"
        var lines = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        func entry(_ n: String) -> String? { lines.first { $0.hasPrefix("mcp \(n) ") } }
        func save() { try? (lines.sorted().joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8) }
        switch a[0] {
        case "get":
            guard let line = entry(a[1]) else { return CommandResult(status: 1, stderr: "Error: No MCP server named '\(a[1])' found.") }
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            var env: [String: String] = [:]
            if parts.count > 3 { for kv in parts[3].split(separator: ",") { let p = kv.split(separator: "=", maxSplits: 1); env[String(p[0])] = String(p[1]) } }
            let json: [String: Any] = ["name": a[1], "transport": ["type": "stdio", "command": parts[2], "args": [String](), "env": env]]
            return CommandResult(status: 0, stdout: String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        case "add":
            var env: [String] = []
            var i = 2
            while a[i] != "--" { if a[i] == "--env" { env.append(a[i + 1]); i += 2 } else { i += 1 } }
            lines.removeAll { $0.hasPrefix("mcp \(a[1]) ") }
            lines.append("mcp \(a[1]) \(a[i + 1])" + (env.isEmpty ? "" : " " + env.joined(separator: ",")))
            save()
            return CommandResult(status: 0, stdout: "Added global MCP server '\(a[1])'.")
        case "remove":
            guard entry(a[1]) != nil else { return CommandResult(status: 0, stdout: "No MCP server named '\(a[1])' found.") }
            lines.removeAll { $0.hasPrefix("mcp \(a[1]) ") }
            save()
            return CommandResult(status: 0, stdout: "Removed global MCP server '\(a[1])'.")
        default:
            return CommandResult(status: 2)
        }
    }

    // MARK: claude

    private func claudeRun(_ a: [String], dir: String) -> CommandResult {
        let file = dir + "/.claude.json"
        var obj = (FileManager.default.contents(atPath: file).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        var servers = obj["mcpServers"] as? [String: Any] ?? [:]
        func save() {
            obj["mcpServers"] = servers
            try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: URL(fileURLWithPath: file))
        }
        switch a[0] {
        case "get":
            guard let s = servers[a[1]] as? [String: Any] else { return CommandResult(status: 1, stderr: "No MCP server named \"\(a[1])\".") }
            let ok = FileManager.default.isExecutableFile(atPath: s["command"] as? String ?? "")
            return CommandResult(status: 0, stdout: "\(a[1]):\n  Scope: User config\n  Status: \(ok ? "✔ Connected" : "✘ Failed to connect")\n")
        case "add":
            #expect(Array(a[1...3]) == ["--scope", "user", Integrations.serverName], "名字要写在 -e 前面（F24）")
            var env: [String: String] = [:]
            var i = 4
            while a[i] != "--" { if a[i] == "-e" { let p = a[i + 1].split(separator: "=", maxSplits: 1); env[String(p[0])] = String(p[1]); i += 2 } else { i += 1 } }
            servers[a[3]] = ["type": "stdio", "command": a[i + 1], "args": [String](), "env": env]
            save()
            return CommandResult(status: 0)
        case "remove":
            guard servers[a[3]] != nil else { return CommandResult(status: 1, stderr: "No MCP server named \"\(a[3])\" in user scope") }
            servers[a[3]] = nil
            save()
            return CommandResult(status: 0)
        default:
            return CommandResult(status: 2)
        }
    }
}

/// 临时目录里的一套接入环境：数据目录、假的 Codex 和 Claude 配置目录
final class IntegrationHarness: @unchecked Sendable {
    let t: TempDir
    let paths: RelayPaths
    let store: Store
    let cli: FakeCLI
    let codexHome: String, claudeDir: String
    var integrations: Integrations!

    init(defaultHome: Bool = false, codexMissing: Bool = false, claudeMissing: Bool = false) throws {
        t = try TempDir()
        let userHome = t.path + "/home"
        paths = defaultHome ? RelayPaths.resolve(environment: [:], userHome: userHome)
                            : RelayPaths.resolve(environment: ["AGENTRELAY_HOME": t.path + "/relay"], userHome: userHome)
        try paths.prepare()
        // 假装应用已建好链接：bin/relay-mcp 是个可执行文件
        try "#!/bin/sh\n".write(toFile: paths.bin + "/relay-mcp", atomically: true, encoding: .utf8)
        chmod(paths.bin + "/relay-mcp", 0o755)
        store = try Store(path: paths.database)
        try FileManager.default.createDirectory(atPath: t.path + "/tools", withIntermediateDirectories: true)
        cli = try FakeCLI(dir: t.path + "/tools")
        codexHome = t.path + "/codex"
        claudeDir = t.path + "/claude"
        for d in [codexHome, claudeDir] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        integrations = Integrations(paths: paths, store: store, runner: cli,
                                    environment: ["CODEX_HOME": codexHome, "CLAUDE_CONFIG_DIR": claudeDir, "PATH": "/usr/bin:/bin"],
                                    userHome: userHome,
                                    codexExecutable: { [cli] in codexMissing ? nil : cli.codex },
                                    claudeExecutable: { [cli] in claudeMissing ? nil : cli.claude })
    }

    var codexFile: String { codexHome + "/config.toml" }
    var claudeFile: String { claudeDir + "/.claude.json" }
    func read(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
    func claudeServers() -> [String: Any] {
        (read(claudeFile).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["mcpServers"] as? [String: Any] ?? [:]
    }
}


@Suite("接入向导")
struct IntegrationsTests {
    @Test("干净环境：两边都没装 → 预览 → 一键装上 → 核对通过；配置改动有记录")
    func cleanInstall() throws {
        let h = try IntegrationHarness()
        let i = h.integrations!
        #expect(i.status(.codex).state == .notInstalled)
        #expect(i.status(.claude).state == .notInstalled)
        #expect(i.expected == MCPEntry(command: h.paths.bin + "/relay-mcp", env: ["AGENTRELAY_HOME": h.paths.home]))

        let pc = i.preview(.codex)
        #expect(pc.commands == [Integrations.display(h.cli.codex, ["mcp", "add", "agent-relay", "--env", "AGENTRELAY_HOME=\(h.paths.home)", "--", h.paths.bin + "/relay-mcp"])])
        #expect(pc.notes.contains { $0.contains("重新排版") })
        let pl = i.preview(.claude)
        #expect(pl.commands.first?.contains("mcp add --scope user agent-relay -e AGENTRELAY_HOME=") == true)
        #expect(pl.notes.contains { $0.contains("工作副本") })

        let rc = i.install(.codex)
        #expect(rc.ok, "\(rc.lines)")
        #expect(rc.lines.contains { $0.contains("原来没有，不用备份") })
        #expect(i.status(.codex).state == .installed)
        let rl = i.install(.claude)
        #expect(rl.ok, "\(rl.lines)")
        #expect(i.status(.claude).state == .installed)

        let vc = i.verify(.codex)
        #expect(vc.ok, "\(vc.lines)")
        let vl = i.verify(.claude)
        #expect(vl.ok, "\(vl.lines)")
        #expect(vl.lines.contains { $0.contains("已连通") })

        let changes = try h.store.configChanges()
        #expect(changes.map(\.action) == [.install, .install])
        #expect(changes.allSatisfy { $0.ok })
        let codexInstall = try #require(try h.store.lastInstall(platform: .codex))
        #expect(!codexInstall.fileExisted && codexInstall.backupPath == nil && codexInstall.snapshotPath != nil)
        // 再装一次不改任何东西
        let before = h.cli.calls.count
        #expect(i.install(.codex).lines.contains { $0.contains("已经装好了") })
        #expect(h.cli.calls(of: h.cli.codex).filter { $0[1] == "add" }.count == 1)
        #expect(h.cli.calls.count == before + 1, "只查了一次状态")
    }

    @Test("默认数据目录：配置里不带 AGENTRELAY_HOME")
    func defaultHome() throws {
        let h = try IntegrationHarness(defaultHome: true)
        #expect(h.integrations.expected.env.isEmpty)
        #expect(!h.integrations.preview(.codex).commands[0].contains("--env"))
        #expect(h.integrations.install(.claude).ok)
        #expect((h.claudeServers()["agent-relay"] as? [String: Any])?["env"] as? [String: String] == [:])
    }

    @Test("Codex 卸载：装后没被改过 → 用改前备份逐字还原；改前没有文件 → 删掉新建的文件")
    func codexRestoreUntouched() throws {
        let h = try IntegrationHarness()
        let original = Data("model = \"示例\"\n[projects.\"/示例\"]\ntrust_level = \"trusted\"\n".utf8)
        try original.write(to: URL(fileURLWithPath: h.codexFile))
        chmod(h.codexFile, 0o644)
        #expect(h.integrations.install(.codex).ok)
        #expect(h.read(h.codexFile) != original, "假 codex 会重新排版")
        let r = h.integrations.uninstall(.codex)
        #expect(r.ok, "\(r.lines)")
        #expect(r.lines.contains { $0.contains("一字不差") })
        #expect(h.read(h.codexFile) == original)
        let mode = (try FileManager.default.attributesOfItem(atPath: h.codexFile)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o644, "还原时保留原来的权限")
        #expect(!h.cli.calls(of: h.cli.codex).contains { $0[1] == "remove" }, "逐字还原不需要运行 codex")

        let fresh = try IntegrationHarness()
        #expect(fresh.integrations.install(.codex).ok)
        #expect(fresh.integrations.uninstall(.codex).ok)
        #expect(!FileManager.default.fileExists(atPath: fresh.codexFile), "安装时新建的 config.toml 卸载时删掉")
    }

    @Test("Codex 卸载：装后被别的程序改过 → 用官方命令移除，保留别人后来写进去的设置")
    func codexRemoveWhenChanged() throws {
        let h = try IntegrationHarness()
        try "model = \"示例\"\n".write(toFile: h.codexFile, atomically: true, encoding: .utf8)
        #expect(h.integrations.install(.codex).ok)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: h.codexFile))
        handle.seekToEndOfFile()
        handle.write(Data("后来写进去的设置 = 1\n".utf8))
        try handle.close()
        let r = h.integrations.uninstall(.codex)
        #expect(r.ok, "\(r.lines)")
        #expect(r.lines.contains { $0.contains("排版会变") })
        let text = try String(contentsOfFile: h.codexFile, encoding: .utf8)
        #expect(text.contains("后来写进去的设置 = 1"))
        #expect(!text.contains("agent-relay"))
        #expect(h.integrations.status(.codex).state == .notInstalled)
        #expect(try h.store.configChanges().first?.action == .uninstall)
    }

    @Test("Claude：只通过官方命令改；卸载后 mcpServers 和别的设置都和安装前一样")
    func claudeRoundTrip() throws {
        let h = try IntegrationHarness()
        let original: [String: Any] = ["userID": "示例", "mcpServers": ["别的服务": ["type": "stdio", "command": "/usr/bin/true"]],
                                       "projects": ["/示例": ["mcpServers": [String: Any]()]]]
        try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]).write(to: URL(fileURLWithPath: h.claudeFile))
        #expect(h.integrations.install(.claude).ok)
        #expect(h.claudeServers().keys.sorted() == ["agent-relay", "别的服务"])
        let r = h.integrations.uninstall(.claude)
        #expect(r.ok, "\(r.lines)")
        let after = try #require(h.read(h.claudeFile).flatMap { try JSONSerialization.jsonObject(with: $0) as? NSDictionary })
        #expect(after == original as NSDictionary)
        #expect(h.cli.calls(of: h.cli.claude).map { $0[1] }.filter { $0 != "get" } == ["add", "remove"])
        // 备份：0600，备份目录 0700
        let backups = try FileManager.default.contentsOfDirectory(atPath: h.paths.backups)
        #expect(backups.count == 2)
        for b in backups {
            let mode = (try FileManager.default.attributesOfItem(atPath: h.paths.backups + "/" + b)[.posixPermissions] as? NSNumber)?.intValue
            #expect(mode == 0o600)
        }
        let dirMode = (try FileManager.default.attributesOfItem(atPath: h.paths.backups)[.posixPermissions] as? NSNumber)?.intValue
        #expect(dirMode == 0o700)
    }

    @Test("指向别的数据目录：安装时先移除旧的再装；同名但不是 AgentRelay 的：不碰")
    func elsewhereAndForeign() throws {
        let h = try IntegrationHarness()
        try "mcp agent-relay /旧位置/bin/relay-mcp AGENTRELAY_HOME=/旧位置\n".write(toFile: h.codexFile, atomically: true, encoding: .utf8)
        guard case .pointsElsewhere(let old) = h.integrations.status(.codex).state else { Issue.record("应当认出指向别处"); return }
        #expect(old.home == "/旧位置")
        #expect(h.integrations.preview(.codex).commands.count == 2)
        let r = h.integrations.install(.codex)
        #expect(r.ok, "\(r.lines)")
        #expect(h.cli.calls(of: h.cli.codex).map { $0[1] }.filter { $0 != "get" } == ["remove", "add"])
        #expect(h.integrations.status(.codex).state == .installed)

        let f = try IntegrationHarness()
        let foreign: [String: Any] = ["mcpServers": ["agent-relay": ["type": "stdio", "command": "/usr/local/bin/别人的工具"]]]
        let data = try JSONSerialization.data(withJSONObject: foreign)
        try data.write(to: URL(fileURLWithPath: f.claudeFile))
        guard case .foreign = f.integrations.status(.claude).state else { Issue.record("应当认出同名的别人的服务"); return }
        #expect(!f.integrations.install(.claude).ok)
        #expect(!f.integrations.uninstall(.claude).ok)
        #expect(f.read(f.claudeFile) == data, "同名的别人的服务不能动")
        #expect(f.cli.calls(of: f.cli.claude).isEmpty)
    }

    @Test("命令失败、找不到程序：不算装好，失败也记一笔；给出手动步骤")
    func failures() throws {
        let h = try IntegrationHarness()
        h.cli.failures["codex add"] = CommandResult(status: 1, stderr: "示例错误")
        let r = h.integrations.install(.codex)
        #expect(!r.ok)
        #expect(r.lines.last?.contains("示例错误") == true)
        #expect(try h.store.configChanges().first?.ok == false)
        #expect(try h.store.lastInstall(platform: .codex) == nil)

        let m = try IntegrationHarness(codexMissing: true, claudeMissing: true)
        guard case .unknown(let why) = m.integrations.status(.codex).state else { Issue.record("找不到 codex 时查不出状态"); return }
        #expect(why.contains("找不到 codex"))
        #expect(!m.integrations.install(.codex).ok)
        #expect(m.integrations.status(.claude).state == .notInstalled, "Claude 的状态直接读配置文件，不需要程序")
        #expect(!m.integrations.install(.claude).ok)
        let steps = m.integrations.manualSteps(.claude)
        #expect(steps.install == ["claude mcp add --scope user agent-relay -e AGENTRELAY_HOME=\(m.paths.home) -- \(m.paths.bin)/relay-mcp"])
        #expect(steps.uninstall == ["claude mcp remove --scope user agent-relay"])
        #expect(try m.store.configChanges().isEmpty, "找不到程序时什么都没改，不记")
    }

    @Test("核对：配置不对或 relay-mcp 不能启动时不通过")
    func verifyFailures() throws {
        let h = try IntegrationHarness()
        #expect(!h.integrations.verify(.codex).ok)
        #expect(h.integrations.install(.codex).ok)
        unlink(h.paths.bin + "/relay-mcp")
        let v = h.integrations.verify(.codex)
        #expect(!v.ok)
        #expect(v.lines.contains { $0.contains("找不到") && $0.contains("relay-mcp") })
    }

    @Test("完全卸载：两边先卸，失败就停；删文件只删固定的几个子目录")
    func fullUninstall() throws {
        let h = try IntegrationHarness()
        #expect(h.integrations.install(.codex).ok)
        #expect(h.integrations.install(.claude).ok)
        h.cli.failures["codex remove"] = CommandResult(status: 1, stderr: "示例错误")
        try "后来写进去的设置 = 1\n".write(toFile: h.codexFile + ".x", atomically: true, encoding: .utf8)
        // 让 Codex 走官方命令那条路（装后被改过），并让它失败
        try (String(contentsOfFile: h.codexFile, encoding: .utf8) + "另一行\n").write(toFile: h.codexFile, atomically: true, encoding: .utf8)
        var steps = FullUninstall.removeIntegrations(h.integrations)
        #expect(steps.count == 1 && !steps[0].ok, "Codex 失败就不再动 Claude")
        #expect(h.integrations.status(.claude).state == .installed)
        h.cli.failures = [:]
        steps = FullUninstall.removeIntegrations(h.integrations)
        #expect(steps.count == 2 && steps.allSatisfy { $0.ok }, "\(steps)")

        // 自定义数据目录：数据库、日志都在数据目录里，保留数据时数据目录不删
        h.store.close()
        steps = FullUninstall.deleteFiles(paths: h.paths, deleteData: false)
        #expect(steps.allSatisfy { $0.ok })
        #expect(!FileManager.default.fileExists(atPath: h.paths.bin))
        #expect(!FileManager.default.fileExists(atPath: h.paths.run))
        #expect(FileManager.default.fileExists(atPath: h.paths.database))
        #expect(FileManager.default.fileExists(atPath: h.paths.home))
        steps = FullUninstall.deleteFiles(paths: h.paths, deleteData: true)
        #expect(steps.allSatisfy { $0.ok })
        #expect(!FileManager.default.fileExists(atPath: h.paths.home))
        #expect(FileManager.default.fileExists(atPath: h.codexFile), "不碰两边的配置文件本身")

        // 默认位置：数据库和日志在 ~/Library 下，保留数据时只删 ~/.agentrelay
        let d = try IntegrationHarness(defaultHome: true)
        d.store.close()
        _ = FullUninstall.deleteFiles(paths: d.paths, deleteData: false)
        #expect(!FileManager.default.fileExists(atPath: d.paths.home))
        #expect(FileManager.default.fileExists(atPath: d.paths.database))
        _ = FullUninstall.deleteFiles(paths: d.paths, deleteData: true)
        #expect(!FileManager.default.fileExists(atPath: d.paths.data))
        #expect(!FileManager.default.fileExists(atPath: d.paths.logs))
    }

    @Test("数据库关掉后再用会报错，不会悄悄重建文件")
    func storeClose() throws {
        let h = try IntegrationHarness()
        h.store.close()
        #expect(throws: RelayError.self) { try h.store.configChanges() }
    }

    @Test("命令行显示：有空格或特殊字符的参数加引号")
    func display() {
        #expect(Integrations.display("/a/codex", ["mcp", "add", "x", "--", "/Users/示例/My Dir/relay-mcp"])
                == "/a/codex mcp add x -- '/Users/示例/My Dir/relay-mcp'")
        #expect(Integrations.display("claude", ["it's"]) == #"claude 'it'\''s'"#)
    }

    @Test("找 claude 程序：设置里填的 → ~/.local/bin → 最后才用桌面版自带的")
    func locateClaude() throws {
        let t = try TempDir()
        let home = t.path
        func makeExe(_ p: String) throws {
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(toFile: p, atomically: true, encoding: .utf8)
            chmod(p, 0o755)
        }
        #expect(ClaudeCLI.locate(configuredPath: nil, userHome: home, environment: ["PATH": ""]) == nil)
        let bundled = home + "/Library/Application Support/Claude-3p/claude-code/1.0.0/abc/claude.app/Contents/MacOS/claude"
        try makeExe(bundled)
        #expect(ClaudeCLI.locate(configuredPath: nil, userHome: home, environment: ["PATH": ""]) == bundled)
        try makeExe(home + "/.local/bin/claude")
        #expect(ClaudeCLI.locate(configuredPath: nil, userHome: home, environment: ["PATH": ""]) == home + "/.local/bin/claude")
        try makeExe(home + "/自定义/claude")
        #expect(ClaudeCLI.locate(configuredPath: home + "/自定义/claude", userHome: home, environment: ["PATH": ""]) == home + "/自定义/claude")
    }

    @Test("运行命令：分开收集输出、写入标准输入、超时结束、PATH 补齐")
    func systemRunner() {
        let r = SystemCommandRunner()
        let a = r.run("/bin/sh", ["-c", "echo 正常; echo 出错 >&2; exit 3"], environment: [:], currentDirectory: "/", input: nil, timeout: 5)
        #expect(a.status == 3 && a.stdout == "正常\n" && a.stderr == "出错\n")
        #expect(a.brief == "出错")
        let b = r.run("/bin/cat", [], environment: [:], currentDirectory: nil, input: Data("你好".utf8), timeout: 5)
        #expect(b.stdout == "你好")
        let c = r.run("/bin/sleep", ["5"], environment: [:], currentDirectory: nil, input: nil, timeout: 0.3)
        #expect(c.timedOut && c.brief == "超时")
        let env = SystemCommandRunner.environment(for: "/opt/示例/bin/claude", base: ["PATH": "/usr/bin"], userHome: "/Users/示例", extra: ["K": "V"])
        let path = env["PATH"]!.split(separator: ":").map(String.init)
        #expect(path.first == "/usr/bin")
        #expect(path.contains("/opt/示例/bin") && path.contains("/Users/示例/.local/bin") && path.contains("/opt/homebrew/bin"))
        #expect(env["K"] == "V")
    }
}

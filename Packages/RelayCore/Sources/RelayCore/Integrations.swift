import Foundation

// MARK: - 配置改动记录（设计方案第 17 节 `config_changes`）

public enum ConfigAction: String, Sendable {
    case install, uninstall
}

public struct ConfigChangeRow: Sendable, Equatable, Identifiable {
    public let id: Int
    public let time: Date
    public let platform: Platform
    public let action: ConfigAction
    /// 改的是哪个配置文件
    public let target: String
    /// 改之前这个文件在不在（干净环境里 `config.toml` 可能还没有）
    public let fileExisted: Bool
    /// 改前备份；改前没有文件时为 nil
    public let backupPath: String?
    /// 装后快照（只有 Codex 安装时有），卸载时用来判断装后有没有被别的程序改过
    public let snapshotPath: String?
    public let summary: String
    public let ok: Bool
}

extension Store {
    @discardableResult
    public func addConfigChange(platform: Platform, action: ConfigAction, target: String, fileExisted: Bool,
                                backupPath: String?, snapshotPath: String?, summary: String, ok: Bool, at now: Date) throws -> ConfigChangeRow {
        try locked {
            try db.query("""
            INSERT INTO config_changes (time, platform, action, target, file_existed, backup_path, snapshot_path, summary, ok)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [SQLValue(now), .text(platform.rawValue), .text(action.rawValue), .text(target), SQLValue(fileExisted),
                  SQLValue(backupPath), SQLValue(snapshotPath), .text(summary), SQLValue(ok)])
            return try configChangeRows("WHERE id = last_insert_rowid()", [])[0]
        }
    }

    /// 最近的配置改动，新的在前
    public func configChanges(limit: Int = 50) throws -> [ConfigChangeRow] {
        try locked { try configChangeRows("ORDER BY id DESC LIMIT ?", [.int(limit)]) }
    }

    /// 某个平台最近一次成功的安装
    public func lastInstall(platform: Platform) throws -> ConfigChangeRow? {
        try locked {
            try configChangeRows("WHERE platform = ? AND action = 'install' AND ok = 1 ORDER BY id DESC LIMIT 1", [.text(platform.rawValue)]).first
        }
    }

    private func configChangeRows(_ tail: String, _ params: [SQLValue]) throws -> [ConfigChangeRow] {
        try db.query("SELECT * FROM config_changes " + tail, params).map { r in
            ConfigChangeRow(id: r.int("id")!, time: r.date("time")!, platform: Platform(rawValue: r.string("platform")!) ?? .codex,
                            action: ConfigAction(rawValue: r.string("action")!) ?? .install, target: r.string("target")!,
                            fileExisted: r.bool("file_existed"), backupPath: r.string("backup_path"),
                            snapshotPath: r.string("snapshot_path"), summary: r.string("summary")!, ok: r.bool("ok"))
        }
    }
}

// MARK: - 接入状态

/// 两边配置里的一项 MCP 服务：只取命令、参数和环境变量，不看别的服务
public struct MCPEntry: Sendable, Equatable {
    public var command: String
    public var args: [String]
    public var env: [String: String]

    public init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }

    /// 是不是 AgentRelay 的 relay-mcp（按程序名判断）
    public var isRelayMCP: Bool { (command as NSString).lastPathComponent == "relay-mcp" && args.isEmpty }

    /// 指向的数据目录：环境变量里没写就是默认位置
    public var home: String? { env["AGENTRELAY_HOME"] }
}

public enum IntegrationState: Sendable, Equatable {
    /// 没装
    case notInstalled
    /// 装好了，指向当前数据目录
    case installed
    /// 是 AgentRelay 的，但指向别的位置（例如开发用的数据目录）
    case pointsElsewhere(MCPEntry)
    /// 有同名的 agent-relay，但不是 AgentRelay 装的；不碰它
    case foreign(MCPEntry)
    /// 查不出来
    case unknown(String)
}

public struct IntegrationStatus: Sendable, Equatable {
    public let platform: Platform
    /// codex / claude 程序；找不到时为 nil
    public let executable: String?
    /// 会改的配置文件
    public let configFile: String
    public let state: IntegrationState
    /// 装好后配置里应有的样子
    public let expected: MCPEntry
}

/// 一次操作（安装、核对、卸载）的结果，逐行写给你看
public struct IntegrationReport: Sendable, Equatable {
    public var ok: Bool
    public var lines: [String]
    public var change: ConfigChangeRow?

    public init(ok: Bool, lines: [String], change: ConfigChangeRow? = nil) {
        self.ok = ok
        self.lines = lines
        self.change = change
    }
}

/// 预览：要运行的命令、会改的文件和要知道的事
public struct IntegrationPreview: Sendable, Equatable {
    public let commands: [String]
    public let file: String
    public let notes: [String]
}

// MARK: - 接入向导（设计方案第 13 节）

/// 给 Codex、Claude 接入或移除传话工具。一律调用两边自己的命令，不手写 TOML 和 JSON；
/// 唯一例外是 Codex 卸载时，配置装后没被改过，就用改前备份逐字还原（第 13.1 节第 6 点）。
/// Claude 装成全局（`--scope user`，第 24 节第 15 项）。所有方法都会阻塞几秒，界面要放到后台调用。
public final class Integrations: @unchecked Sendable {
    public static let serverName = "agent-relay"

    public let paths: RelayPaths
    let store: Store
    let runner: CommandRunning
    /// 运行两边命令时的基础环境（测试里在这里放 `CODEX_HOME`、`CLAUDE_CONFIG_DIR`，把改动关在临时目录）
    let environment: [String: String]
    let userHome: String
    let codexExecutable: @Sendable () -> String?
    let claudeExecutable: @Sendable () -> String?
    let clock: @Sendable () -> Date
    let timeout: TimeInterval

    /// - Parameters:
    ///   - codexExecutable: 找 codex 程序的方法。测试必须传入假的，不能用 `CodexCLI.locate`（会找到真的 ChatGPT）
    ///   - claudeExecutable: 找 claude 程序的方法，测试同样传入假的
    public init(paths: RelayPaths, store: Store, runner: CommandRunning = SystemCommandRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment, userHome: String = RelayPaths.userHome(),
                codexExecutable: @escaping @Sendable () -> String?, claudeExecutable: @escaping @Sendable () -> String?,
                clock: @escaping @Sendable () -> Date = { Date() }, timeout: TimeInterval = 60) {
        self.paths = paths
        self.store = store
        self.runner = runner
        self.environment = environment
        self.userHome = userHome
        self.codexExecutable = codexExecutable
        self.claudeExecutable = claudeExecutable
        self.clock = clock
        self.timeout = timeout
    }

    /// 装好后配置里应有的样子：命令是 `<数据目录>/bin/relay-mcp`；数据目录不是默认位置时带上 `AGENTRELAY_HOME`
    /// （Codex 不会把终端里的环境变量传给 MCP 服务，F14）
    public var expected: MCPEntry {
        let isDefault = paths == RelayPaths.resolve(environment: [:], userHome: userHome)
        return MCPEntry(command: paths.bin + "/relay-mcp", env: isDefault ? [:] : ["AGENTRELAY_HOME": paths.home])
    }

    /// 会改的配置文件
    public func configFile(_ p: Platform) -> String {
        switch p {
        case .codex:
            let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? userHome + "/.codex"
            return RelayPaths.expandTilde(home, userHome: userHome) + "/config.toml"
        case .claude:
            if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
                return RelayPaths.expandTilde(dir, userHome: userHome) + "/.claude.json"
            }
            return userHome + "/.claude.json"
        }
    }

    private func executable(_ p: Platform) -> String? {
        let exe = p == .codex ? codexExecutable() : claudeExecutable()
        guard let exe, FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        return exe
    }

    private func tool(_ p: Platform) -> String { p == .codex ? "codex" : "claude" }

    private func run(_ exe: String, _ args: [String], input: Data? = nil, timeout: TimeInterval? = nil) -> CommandResult {
        runner.run(exe, args, environment: SystemCommandRunner.environment(for: exe, base: environment, userHome: userHome),
                   currentDirectory: userHome, input: input, timeout: timeout ?? self.timeout)
    }

    // MARK: 检查

    public func status(_ p: Platform) -> IntegrationStatus {
        let exe = executable(p)
        let state: IntegrationState
        switch p {
        case .codex:
            if let exe { state = codexState(exe) } else { state = .unknown("找不到 codex 程序（ChatGPT 桌面版没装，或者路径不对）") }
        case .claude:
            state = claudeState()
        }
        return IntegrationStatus(platform: p, executable: exe, configFile: configFile(p), state: state, expected: expected)
    }

    private func classify(_ entry: MCPEntry) -> IntegrationState {
        guard entry.isRelayMCP else { return .foreign(entry) }
        return entry == expected ? .installed : .pointsElsewhere(entry)
    }

    /// Codex：`codex mcp get agent-relay --json`，只取我们这一项
    private func codexState(_ exe: String) -> IntegrationState {
        let r = run(exe, ["mcp", "get", Self.serverName, "--json"])
        if r.status != 0 {
            if (r.stdout + r.stderr).contains("No MCP server named") { return .notInstalled }
            return .unknown("codex mcp get 失败：\(r.brief)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let transport = obj["transport"] as? [String: Any] else {
            return .unknown("看不懂 codex mcp get 的输出")
        }
        guard let command = transport["command"] as? String else {
            // 同名但不是本机程序（例如网址形式的服务）
            return .foreign(MCPEntry(command: (transport["url"] as? String) ?? "（不是本机程序）"))
        }
        return classify(MCPEntry(command: command, args: transport["args"] as? [String] ?? [],
                                 env: transport["env"] as? [String: String] ?? [:]))
    }

    /// Claude：只读 `~/.claude.json` 顶层 `mcpServers` 里的 `agent-relay` 一项（全局配置就记在这里）
    private func claudeState() -> IntegrationState {
        let file = configFile(.claude)
        guard FileManager.default.fileExists(atPath: file) else { return .notInstalled }
        guard let data = FileManager.default.contents(atPath: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown("读不了 \(file)")
        }
        guard let servers = obj["mcpServers"] as? [String: Any], let mine = servers[Self.serverName] as? [String: Any] else {
            return .notInstalled
        }
        guard let command = mine["command"] as? String else {
            return .foreign(MCPEntry(command: (mine["url"] as? String) ?? "（不是本机程序）"))
        }
        return classify(MCPEntry(command: command, args: mine["args"] as? [String] ?? [], env: mine["env"] as? [String: String] ?? [:]))
    }

    // MARK: 预览、手动教程

    private func addArguments(_ p: Platform) -> [String] {
        let e = expected
        switch p {
        case .codex:
            return ["mcp", "add", Self.serverName] + e.env.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] } + ["--", e.command]
        case .claude:
            // 名字要写在 -e 前面，否则会被当成环境变量吃掉（F24）
            return ["mcp", "add", "--scope", "user", Self.serverName] + e.env.sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] } + ["--", e.command]
        }
    }

    private func removeArguments(_ p: Platform) -> [String] {
        p == .codex ? ["mcp", "remove", Self.serverName] : ["mcp", "remove", "--scope", "user", Self.serverName]
    }

    /// 写给人看的命令行（参数里有空格时加引号）
    public static func display(_ exe: String, _ args: [String]) -> String {
        ([exe] + args).map { a in
            a.contains(where: { " \"'$\\".contains($0) }) ? "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'" : a
        }.joined(separator: " ")
    }

    public func preview(_ p: Platform) -> IntegrationPreview { preview(p, status: status(p)) }

    /// 用已经查到的状态生成预览，不再运行命令（界面在主线程上用）
    public func preview(_ p: Platform, status st: IntegrationStatus) -> IntegrationPreview {
        let exeName = st.executable ?? tool(p)
        var commands: [String] = []
        if case .pointsElsewhere = st.state { commands.append(Self.display(exeName, removeArguments(p))) }
        commands.append(Self.display(exeName, addArguments(p)))
        var notes: [String]
        switch p {
        case .codex:
            notes = [
                "装在全局：所有 Codex 项目新开的会话都能看到这个工具，但只有登记过的项目调用才会成功。",
                "Codex 的官方命令会把 config.toml 里 MCP 那部分重新排版（调整顺序、拆开行内表），内容不变。",
                "改之前先把 config.toml 备份到 \(paths.backups)；卸载时如果装后没被改过，就用备份逐字还原。",
            ]
        case .claude:
            notes = [
                "装在全局：所有 Claude 会话（包括开在 Git 工作副本里的）都能看到这个工具，但只有登记过的项目调用才会成功。每个 Claude 会话会多一份工具说明。",
                "只通过 Claude 的官方命令改 ~/.claude.json，不直接写这个文件；改之前先备份到 \(paths.backups)。",
            ]
        }
        if !expected.env.isEmpty { notes.append("数据目录不是默认位置，会把 AGENTRELAY_HOME=\(paths.home) 一并写进配置。") }
        notes.append("装好后要在登记的项目里新开一个会话才能用；已经开着的会话看不到这个工具。")
        return IntegrationPreview(commands: commands, file: configFile(p), notes: notes)
    }

    /// 一键失败时给你照着做的命令（第 13.4 节）
    public func manualSteps(_ p: Platform) -> (install: [String], uninstall: [String]) {
        manualSteps(p, executable: executable(p))
    }

    /// 同上，程序位置由调用方给出（界面用已经查到的状态，不再查找）
    public func manualSteps(_ p: Platform, executable: String?) -> (install: [String], uninstall: [String]) {
        let exeName = executable ?? tool(p)
        return ([Self.display(exeName, addArguments(p))], [Self.display(exeName, removeArguments(p))])
    }

    // MARK: 备份

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 把配置文件复制进备份目录（0600）；文件不存在时返回 nil
    private func backup(_ p: Platform, label: String) throws -> String? {
        let file = configFile(p)
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        try FileSystem.makeDirectory(paths.backups, mode: 0o700)
        let name = (p == .codex ? "codex-config.toml" : "claude.json") + ".\(Self.stampFormatter.string(from: clock()))-\(UInt16.random(in: 0...UInt16.max)).\(label)"
        let path = paths.backups + "/" + name
        try FileSystem.writeAtomically(data, to: path)
        return path
    }

    @discardableResult
    private func record(_ p: Platform, _ action: ConfigAction, fileExisted: Bool, backup: String?, snapshot: String? = nil,
                        summary: String, ok: Bool) -> ConfigChangeRow? {
        try? store.addConfigChange(platform: p, action: action, target: configFile(p), fileExisted: fileExisted,
                                   backupPath: backup, snapshotPath: snapshot, summary: summary, ok: ok, at: clock())
    }

    // MARK: 安装

    public func install(_ p: Platform) -> IntegrationReport {
        let st = status(p)
        guard let exe = st.executable else {
            return IntegrationReport(ok: false, lines: ["找不到 \(tool(p)) 程序，没有改动。可以在设置里填程序位置，或者照手动步骤做。"])
        }
        switch st.state {
        case .installed:
            return IntegrationReport(ok: true, lines: ["已经装好了，指向当前的数据目录，没有改动。"])
        case .foreign(let e):
            return IntegrationReport(ok: false, lines: ["已有一个同名的 \(Self.serverName)（命令 \(e.command)），不是 AgentRelay 装的，没有改动。请先自己确认并移除它。"])
        case .unknown(let why):
            return IntegrationReport(ok: false, lines: ["查不出现在的配置，没有改动：\(why)"])
        case .notInstalled, .pointsElsewhere:
            break
        }
        let file = configFile(p)
        let existed = FileManager.default.fileExists(atPath: file)
        var lines: [String] = []
        let saved: String?
        do {
            saved = try backup(p, label: "before")
        } catch {
            return IntegrationReport(ok: false, lines: ["备份配置失败，没有改动：\(error)"])
        }
        lines.append(saved.map { "已备份 \(file) → \($0)" } ?? "\(file) 原来没有，不用备份。")

        if case .pointsElsewhere(let old) = st.state {
            let r = run(exe, removeArguments(p))
            guard r.status == 0 else {
                let why = "先移除指向别处（\(old.home ?? "默认位置")）的旧配置失败：\(r.brief)"
                return IntegrationReport(ok: false, lines: lines + [why],
                                         change: record(p, .install, fileExisted: existed, backup: saved, summary: why, ok: false))
            }
            lines.append("已移除指向别处（\(old.home ?? "默认位置")）的旧配置。")
        }
        let r = run(exe, addArguments(p))
        guard r.status == 0 else {
            let why = "\(tool(p)) mcp add 失败：\(r.brief)"
            return IntegrationReport(ok: false, lines: lines + [why],
                                     change: record(p, .install, fileExisted: existed, backup: saved, summary: why, ok: false))
        }
        lines.append("已运行：\(Self.display(exe, addArguments(p)))")
        // Codex 存一份装后快照：卸载时据此判断装后有没有被别的程序改过
        var snapshot: String?
        if p == .codex { snapshot = try? backup(p, label: "after") }
        guard status(p).state == .installed else {
            let why = "命令成功了，但再查一次配置没看到正确的 \(Self.serverName)"
            return IntegrationReport(ok: false, lines: lines + [why],
                                     change: record(p, .install, fileExisted: existed, backup: saved, snapshot: snapshot, summary: why, ok: false))
        }
        lines.append("装好了。请在登记的项目里新开一个会话再使用；已经开着的会话看不到这个工具。")
        let change = record(p, .install, fileExisted: existed, backup: saved, snapshot: snapshot,
                            summary: "装上 \(Self.serverName)，指向 \(expected.command)", ok: true)
        return IntegrationReport(ok: true, lines: lines, change: change)
    }

    // MARK: 核对

    /// 配置里是正确的那一项；`bin/relay-mcp` 能拉起并完成 MCP 握手；Claude 另用官方命令做连通检查
    public func verify(_ p: Platform) -> IntegrationReport {
        var ok = true
        var lines: [String] = []
        let st = status(p)
        if st.state == .installed {
            lines.append("配置正确：\(Self.serverName) 指向 \(expected.command)。")
        } else {
            ok = false
            lines.append("配置不对：\(Self.describe(st.state))")
        }
        let handshake = selfTest()
        if handshake.ok { lines.append("传话服务能正常启动并完成握手。") } else { ok = false; lines.append(handshake.detail) }
        if p == .claude, let exe = st.executable, st.state == .installed {
            let r = run(exe, ["mcp", "get", Self.serverName])
            let line = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("Status:") }
            if let line, line.contains("Connected"), !line.contains("Failed") {
                lines.append("Claude 的官方检查：已连通。")
            } else {
                ok = false
                lines.append("Claude 的官方检查没通过：\(line ?? r.brief)")
            }
        }
        return IntegrationReport(ok: ok, lines: lines)
    }

    /// 自己拉起一次 `bin/relay-mcp` 做 MCP 握手（不连中转核心），证明链接和程序能用
    public func selfTest() -> (ok: Bool, detail: String) {
        let exe = paths.bin + "/relay-mcp"
        guard FileManager.default.isExecutableFile(atPath: exe) else { return (false, "找不到 \(exe)，请先打开 AgentRelay 让它建好链接。") }
        let hello = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agentrelay-selftest","version":"1"}}}"#
        var env = environment
        for (k, v) in expected.env { env[k] = v }
        let r = runner.run(exe, [], environment: env, currentDirectory: userHome, input: Data((hello + "\n").utf8), timeout: 10)
        guard r.status == 0, r.stdout.contains("\"serverInfo\"") else {
            return (false, "传话服务没能完成握手：\(r.brief.isEmpty ? "退出码 \(r.status)" : r.brief)")
        }
        return (true, "")
    }

    public static func describe(_ s: IntegrationState) -> String {
        switch s {
        case .notInstalled: return "没装。"
        case .installed: return "装好了。"
        case .pointsElsewhere(let e): return "装着，但指向别的位置（\(e.home ?? "默认位置")，命令 \(e.command)）。"
        case .foreign(let e): return "有同名的 \(serverName)，但不是 AgentRelay 装的（命令 \(e.command)）。"
        case .unknown(let why): return why
        }
    }

    // MARK: 卸载

    public func uninstall(_ p: Platform) -> IntegrationReport {
        let file = configFile(p)
        let existed = FileManager.default.fileExists(atPath: file)
        // Codex 装后没被改过：用改前备份逐字还原，不需要 codex 程序
        if p == .codex, let restored = restoreCodexIfUntouched() { return restored }

        let st = status(p)
        switch st.state {
        case .notInstalled:
            return IntegrationReport(ok: true, lines: ["本来就没装，没有改动。"])
        case .foreign(let e):
            return IntegrationReport(ok: false, lines: ["配置里的 \(Self.serverName)（命令 \(e.command)）不是 AgentRelay 装的，没有动它。"])
        case .unknown(let why):
            return IntegrationReport(ok: false, lines: ["查不出现在的配置，没有改动：\(why)"])
        case .installed, .pointsElsewhere:
            break
        }
        guard let exe = st.executable else {
            return IntegrationReport(ok: false, lines: ["找不到 \(tool(p)) 程序，没法用官方命令移除。请照手动步骤做。"])
        }
        var lines: [String] = []
        let saved: String?
        do { saved = try backup(p, label: "before-uninstall") } catch {
            return IntegrationReport(ok: false, lines: ["备份配置失败，没有改动：\(error)"])
        }
        if let saved { lines.append("已备份 \(file) → \(saved)") }
        let r = run(exe, removeArguments(p))
        guard r.status == 0 else {
            let why = "\(tool(p)) mcp remove 失败：\(r.brief)"
            return IntegrationReport(ok: false, lines: lines + [why],
                                     change: record(p, .uninstall, fileExisted: existed, backup: saved, summary: why, ok: false))
        }
        lines.append("已运行：\(Self.display(exe, removeArguments(p)))")
        if p == .codex {
            lines.append("config.toml 装后被改过（或者不是本应用装的），所以没有逐字还原，而是用官方命令移除：MCP 那部分的排版会变，内容等价。改前备份在 \(paths.backups)。")
        }
        guard status(p).state == .notInstalled else {
            let why = "命令成功了，但再查一次配置还能看到 \(Self.serverName)"
            return IntegrationReport(ok: false, lines: lines + [why],
                                     change: record(p, .uninstall, fileExisted: existed, backup: saved, summary: why, ok: false))
        }
        lines.append("已移除。已经开着的会话里的传话服务会运行到会话关闭，调用只会得到“AgentRelay 没在运行”之类的错误。")
        let change = record(p, .uninstall, fileExisted: existed, backup: saved, summary: "移除 \(Self.serverName)（官方命令）", ok: true)
        return IntegrationReport(ok: true, lines: lines, change: change)
    }

    /// 当前 `config.toml` 和最近一次安装的装后快照逐字相同时，用改前备份逐字还原（改前没有这个文件就删掉它）；
    /// 不满足条件时返回 nil，交给官方命令移除
    private func restoreCodexIfUntouched() -> IntegrationReport? {
        let file = configFile(.codex)
        guard let last = try? store.lastInstall(platform: .codex), let snapshotPath = last.snapshotPath,
              let snapshot = FileManager.default.contents(atPath: snapshotPath),
              let current = FileManager.default.contents(atPath: file), current == snapshot else { return nil }
        do {
            if last.fileExisted {
                guard let backupPath = last.backupPath, let original = FileManager.default.contents(atPath: backupPath) else { return nil }
                let mode = ((try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions]) as? NSNumber)?.uint16Value ?? 0o600
                try FileSystem.writeAtomically(original, to: file, mode: mode_t(mode))
            } else {
                try FileManager.default.removeItem(atPath: file)
            }
        } catch {
            let why = "逐字还原 config.toml 失败：\(error)"
            return IntegrationReport(ok: false, lines: [why],
                                     change: record(.codex, .uninstall, fileExisted: true, backup: last.backupPath, summary: why, ok: false))
        }
        let what = last.fileExisted ? "用改前备份逐字还原了 \(file)" : "\(file) 是安装时新建的，已删掉"
        let change = record(.codex, .uninstall, fileExisted: true, backup: last.backupPath,
                            summary: "装后没被改过，\(what)", ok: true)
        return IntegrationReport(ok: true, lines: ["config.toml 装后没被别的程序改过，\(what)，和安装前一字不差。"], change: change)
    }
}

// MARK: - 完全卸载（设计方案第 6.3 节）

public struct UninstallStep: Sendable, Equatable {
    public let title: String
    public let ok: Bool
    public let detail: String

    public init(title: String, ok: Bool, detail: String) {
        self.title = title
        self.ok = ok
        self.detail = detail
    }
}

public enum FullUninstall {
    /// 第一阶段（应用还在运行时）：从两边移除传话工具。哪边失败就停下，不做后面的删除
    public static func removeIntegrations(_ integrations: Integrations) -> [UninstallStep] {
        var steps: [UninstallStep] = []
        for p in [Platform.codex, .claude] {
            let r = integrations.uninstall(p)
            steps.append(UninstallStep(title: "从 \(p.displayName) 移除传话工具", ok: r.ok, detail: r.lines.joined(separator: "\n")))
            if !r.ok { break }
        }
        return steps
    }

    /// 第二阶段（应用已停掉中转服务、关掉数据库之后）：删 `bin/`、`run/`；
    /// `deleteData` 为真时再删数据库、备份和日志；数据目录空了就把它也删掉。只删这几个固定的子目录。
    public static func deleteFiles(paths: RelayPaths, deleteData: Bool) -> [UninstallStep] {
        var targets = [("程序链接", paths.bin), ("运行文件", paths.run)]
        if deleteData { targets += [("数据库和备份", paths.data), ("日志", paths.logs)] }
        var steps: [UninstallStep] = []
        let fm = FileManager.default
        for (title, path) in targets {
            guard fm.fileExists(atPath: path) else {
                steps.append(UninstallStep(title: "删除\(title)", ok: true, detail: "\(path) 本来就不在"))
                continue
            }
            do {
                try fm.removeItem(atPath: path)
                steps.append(UninstallStep(title: "删除\(title)", ok: true, detail: path))
            } catch {
                steps.append(UninstallStep(title: "删除\(title)", ok: false, detail: "\(path)：\(error.localizedDescription)"))
                return steps
            }
        }
        // 数据目录里没有别的东西了才删（不保留数据时数据库、日志也在里面，前面已经删掉）
        if let rest = try? fm.contentsOfDirectory(atPath: paths.home), rest.filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(atPath: paths.home)
            steps.append(UninstallStep(title: "删除数据目录", ok: true, detail: paths.home))
        }
        return steps
    }
}

import Foundation

// MARK: - Codex 钩子：立即引导（调研报告第 7.3 节）

/// 钩子装在哪：全局（`~/.codex/hooks.json`，所有 Codex 会话）或者某个项目文件夹（`<项目>/.codex/hooks.json`，
/// 只对开在这个文件夹里的会话生效，而且 Codex 要先信任这个文件夹）。开发验收时建议只装在测试项目里。
public enum HookScope: Sendable, Equatable {
    case global
    case project(String)
}

public enum HookInstallState: Sendable, Equatable {
    /// 没装
    case notInstalled
    /// 五个事件都装好了，指向当前数据目录
    case installed
    /// 只装了一部分（例如被手动删掉几条），重新安装可以补齐
    case partial(missing: [String])
    /// 文件看不懂，不碰
    case unknown(String)
}

public struct HookStatus: Sendable, Equatable {
    public let scope: HookScope
    /// 会改的文件
    public let file: String
    public let state: HookInstallState
    /// 同一个文件里别的 AgentRelay（别的数据目录，例如正式版和开发版）装的 relay-hook 命令，只显示，不动它们
    public let others: [String]
}

extension Integrations {
    /// 装的事件：UserPromptSubmit、Interrupt 只用来记轮次状态；PreToolUse、PostToolUse、Stop 用来注入
    public static let hookEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt"]
    /// 给 Codex 的时限（秒）；relay-hook 等中转核心最多 5 秒
    public static let hookTimeout = 10

    /// 钩子命令：`<数据目录>/bin/relay-hook`，数据目录不是默认位置时带 `--home`。Codex 用 `$SHELL -lc` 运行它
    public var hookCommand: String {
        let isDefault = paths == RelayPaths.resolve(environment: [:], userHome: userHome)
        var parts = [paths.bin + "/relay-hook"]
        if !isDefault { parts += ["--home", paths.home] }
        return parts.map(Self.shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-+=:@".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Codex 的数据目录（`CODEX_HOME`，默认 `~/.codex`）
    var codexHome: String {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? userHome + "/.codex"
        return RelayPaths.expandTilde(home, userHome: userHome)
    }

    public func hooksFile(_ scope: HookScope) -> String {
        switch scope {
        case .global: return codexHome + "/hooks.json"
        case .project(let dir): return PathMatcher.normalize(RelayPaths.expandTilde(dir, userHome: userHome)) + "/.codex/hooks.json"
        }
    }

    /// 是不是 relay-hook 的命令（按程序名判断，不管指向哪个数据目录）
    static func isRelayHook(_ command: String) -> Bool {
        let first = command.split(separator: " ").first.map(String.init) ?? command
        return (first.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) as NSString).lastPathComponent == "relay-hook"
    }

    /// 读 hooks.json：文件不在返回空对象；看不懂抛错
    private func readHooks(_ file: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: file) else { return [:] }
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayError(.internalError, "\(file) 不是 JSON 对象")
        }
        if let hooks = obj["hooks"], !(hooks is [String: Any]) {
            throw RelayError(.internalError, "\(file) 里的 hooks 不是对象")
        }
        return obj
    }

    /// 某个事件下所有命令
    private static func commands(_ obj: [String: Any], event: String) -> [String] {
        let groups = ((obj["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
    }

    public func hookStatus(_ scope: HookScope) -> HookStatus {
        let file = hooksFile(scope)
        let obj: [String: Any]
        do { obj = try readHooks(file) } catch {
            return HookStatus(scope: scope, file: file, state: .unknown("\(error)"), others: [])
        }
        let mine = hookCommand
        var missing: [String] = []
        var others = Set<String>()
        for event in Self.hookEvents {
            let cmds = Self.commands(obj, event: event)
            if !cmds.contains(mine) { missing.append(event) }
            for c in cmds where c != mine && Self.isRelayHook(c) { others.insert(c) }
        }
        let state: HookInstallState = missing.isEmpty ? .installed : missing.count == Self.hookEvents.count ? .notInstalled : .partial(missing: missing)
        return HookStatus(scope: scope, file: file, state: state, others: others.sorted())
    }

    /// 装之前给你看的说明
    public func hookPreview(_ scope: HookScope) -> IntegrationPreview {
        var notes = [
            "往 \(hooksFile(scope)) 里加 5 条钩子（\(Self.hookEvents.joined(separator: "、"))），命令都是 \(hookCommand)；文件里原有的钩子不动。改之前先备份到 \(paths.backups)。",
            "装好后要你本人在 Codex 里信任这些钩子（输入框上方的 Review hooks，或“设置 › Hooks”）。没被信任的钩子不会运行，AgentRelay 不会替你写信任记录。钩子内容一变就要重新信任。",
            "钩子在 Codex 的沙盒外运行。每个会话每次开始、结束一条命令都会启动一次 relay-hook；没登记的会话它立刻放行，不连 AgentRelay。",
            "只有登记过的 Codex 会话收得到“立即引导”的信：对方下一次开始新动作之前被拦下、先收到通知，正文由它自己用 relay_inbox 读取。",
        ]
        if case .project = scope {
            notes.append("只装在这个项目文件夹里：只对开在这个文件夹里的会话生效，而且 Codex 要先信任这个文件夹。")
        } else {
            notes.append("装在全局：所有 Codex 会话都会运行这些钩子。开发、测试时可以先只装到一个测试项目文件夹里。")
        }
        return IntegrationPreview(commands: [], file: hooksFile(scope), notes: notes)
    }

    private func recordHookChange(_ action: ConfigAction, file: String, existed: Bool, backup: String?, snapshot: String? = nil,
                                  summary: String, ok: Bool) -> ConfigChangeRow? {
        try? store.addConfigChange(platform: .codex, action: action, target: file, fileExisted: existed, backupPath: backup,
                                   snapshotPath: snapshot, summary: summary, ok: ok, at: clock())
    }

    private func writeHooks(_ obj: [String: Any], to file: String) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileSystem.makeDirectory((file as NSString).deletingLastPathComponent, mode: 0o700)
        let mode = ((try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions]) as? NSNumber)?.uint16Value ?? 0o600
        try FileSystem.writeAtomically(data + Data("\n".utf8), to: file, mode: mode_t(mode))
    }

    /// 备份后把 5 条钩子加进 hooks.json（已有的不重复加）
    public func installHooks(_ scope: HookScope) -> IntegrationReport {
        let file = hooksFile(scope)
        if case .project(let dir) = scope {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: RelayPaths.expandTilde(dir, userHome: userHome), isDirectory: &isDir), isDir.boolValue else {
                return IntegrationReport(ok: false, lines: ["项目文件夹不存在：\(dir)，没有改动。"])
            }
        }
        guard FileManager.default.isExecutableFile(atPath: paths.bin + "/relay-hook") else {
            return IntegrationReport(ok: false, lines: ["找不到 \(paths.bin)/relay-hook，请先打开 AgentRelay 让它建好程序链接。没有改动。"])
        }
        var obj: [String: Any]
        do { obj = try readHooks(file) } catch {
            return IntegrationReport(ok: false, lines: ["看不懂现在的 \(file)，没有改动：\(error)"])
        }
        if hookStatus(scope).state == .installed {
            return IntegrationReport(ok: true, lines: ["钩子已经装好了，指向当前的数据目录，没有改动。"])
        }
        let existed = FileManager.default.fileExists(atPath: file)
        var lines: [String] = []
        let saved: String?
        do { saved = try backup(file: file, name: "codex-hooks.json", label: "before") } catch {
            return IntegrationReport(ok: false, lines: ["备份 \(file) 失败，没有改动：\(error)"])
        }
        lines.append(saved.map { "已备份 \(file) → \($0)" } ?? "\(file) 原来没有，不用备份。")

        var hooks = (obj["hooks"] as? [String: Any]) ?? [:]
        let handler: [String: Any] = ["type": "command", "command": hookCommand, "timeout": Self.hookTimeout]
        var added: [String] = []
        for event in Self.hookEvents where !Self.commands(obj, event: event).contains(hookCommand) {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            var group: [String: Any] = ["hooks": [handler]]
            if event == "PreToolUse" || event == "PostToolUse" { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
            added.append(event)
        }
        obj["hooks"] = hooks
        do { try writeHooks(obj, to: file) } catch {
            let why = "写入 \(file) 失败：\(error)"
            return IntegrationReport(ok: false, lines: lines + [why],
                                     change: recordHookChange(.install, file: file, existed: existed, backup: saved, summary: why, ok: false))
        }
        lines.append("已加入钩子：\(added.joined(separator: "、"))。")
        let snapshot = try? backup(file: file, name: "codex-hooks.json", label: "after")
        guard hookStatus(scope).state == .installed else {
            let why = "写好了，但再查一次没看到完整的钩子"
            return IntegrationReport(ok: false, lines: lines + [why],
                                     change: recordHookChange(.install, file: file, existed: existed, backup: saved, snapshot: snapshot, summary: why, ok: false))
        }
        lines.append("还差一步：请在 Codex 里信任这些钩子（输入框上方的 Review hooks，或“设置 › Hooks”）。信任之前它们不会运行。")
        if case .project = scope { lines.append("项目里的钩子只在 Codex 信任了这个项目文件夹后才加载。") }
        let change = recordHookChange(.install, file: file, existed: existed, backup: saved, snapshot: snapshot,
                                      summary: "装上立即引导钩子（\(added.count) 条），命令 \(hookCommand)", ok: true)
        return IntegrationReport(ok: true, lines: lines, change: change)
    }

    /// 移除我们加的钩子：文件装后没被改过时用改前备份逐字还原，否则只删命令完全相同的那几条
    public func uninstallHooks(_ scope: HookScope) -> IntegrationReport {
        let file = hooksFile(scope)
        let existed = FileManager.default.fileExists(atPath: file)
        if let last = try? store.lastInstall(platform: .codex, target: file), let snapshotPath = last.snapshotPath,
           let snapshot = FileManager.default.contents(atPath: snapshotPath),
           let current = FileManager.default.contents(atPath: file), current == snapshot {
            do {
                if last.fileExisted, let backupPath = last.backupPath, let original = FileManager.default.contents(atPath: backupPath) {
                    let mode = ((try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions]) as? NSNumber)?.uint16Value ?? 0o600
                    try FileSystem.writeAtomically(original, to: file, mode: mode_t(mode))
                } else if !last.fileExisted {
                    try FileManager.default.removeItem(atPath: file)
                    removeEmptyCodexFolder(scope)
                } else {
                    throw RelayError(.internalError, "改前备份不见了")
                }
                let what = last.fileExisted ? "用改前备份逐字还原了 \(file)" : "\(file) 是安装时新建的，已删掉"
                let change = recordHookChange(.uninstall, file: file, existed: true, backup: last.backupPath, summary: "钩子文件装后没被改过，\(what)", ok: true)
                return IntegrationReport(ok: true, lines: ["装后没被别的程序改过，\(what)，和安装前一字不差。", Self.trustLeftover], change: change)
            } catch {
                // 还原不了就按条删
            }
        }
        var obj: [String: Any]
        do { obj = try readHooks(file) } catch {
            return IntegrationReport(ok: false, lines: ["看不懂现在的 \(file)，没有改动：\(error)"])
        }
        var hooks = (obj["hooks"] as? [String: Any]) ?? [:]
        var removed = 0
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            for i in groups.indices {
                guard var handlers = groups[i]["hooks"] as? [[String: Any]] else { continue }
                let before = handlers.count
                handlers.removeAll { ($0["command"] as? String) == hookCommand }
                removed += before - handlers.count
                groups[i]["hooks"] = handlers
            }
            groups.removeAll { (($0["hooks"] as? [Any]) ?? []).isEmpty }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        guard removed > 0 else { return IntegrationReport(ok: true, lines: ["\(file) 里没有本数据目录的钩子，没有改动。"]) }
        var lines: [String] = []
        let saved: String?
        do { saved = try backup(file: file, name: "codex-hooks.json", label: "before-uninstall") } catch {
            return IntegrationReport(ok: false, lines: ["备份 \(file) 失败，没有改动：\(error)"])
        }
        if let saved { lines.append("已备份 \(file) → \(saved)") }
        obj["hooks"] = hooks
        do { try writeHooks(obj, to: file) } catch {
            let why = "写入 \(file) 失败：\(error)"
            return IntegrationReport(ok: false, lines: lines + [why],
                                     change: recordHookChange(.uninstall, file: file, existed: existed, backup: saved, summary: why, ok: false))
        }
        lines.append("已移除 \(removed) 条钩子；文件里别的钩子没动（排版可能变了，内容等价）。")
        lines.append(Self.trustLeftover)
        let change = recordHookChange(.uninstall, file: file, existed: existed, backup: saved, summary: "移除立即引导钩子（\(removed) 条）", ok: true)
        return IntegrationReport(ok: true, lines: lines, change: change)
    }

    static let trustLeftover = "Codex 里对这些钩子的信任记录还在（钩子已经删了，不会再运行）；要清理请在 Codex 的“设置 › Hooks”里处理。"

    private func removeEmptyCodexFolder(_ scope: HookScope) {
        guard case .project = scope else { return }
        let dir = (hooksFile(scope) as NSString).deletingLastPathComponent
        if let rest = try? FileManager.default.contentsOfDirectory(atPath: dir), rest.isEmpty { try? FileManager.default.removeItem(atPath: dir) }
    }

    /// 核对：钩子都在；relay-hook 能运行并放行；最近有没有收到过登记会话的钩子上报（说明钩子已被信任、在运行）
    public func verifyHooks(_ scope: HookScope, lastReport: Date?) -> IntegrationReport {
        var ok = true
        var lines: [String] = []
        let st = hookStatus(scope)
        switch st.state {
        case .installed: lines.append("钩子都在：\(st.file)。")
        case .notInstalled: ok = false; lines.append("没装钩子。")
        case .partial(let missing): ok = false; lines.append("少了这些钩子：\(missing.joined(separator: "、"))，重新安装可以补齐。")
        case .unknown(let why): ok = false; lines.append(why)
        }
        let exe = paths.bin + "/relay-hook"
        if FileManager.default.isExecutableFile(atPath: exe) {
            let probe = #"{"hook_event_name":"PreToolUse","session_id":"00000000-0000-4000-8000-000000000000","turn_id":"selftest","tool_name":"Bash"}"#
            let r = runner.run(exe, paths == RelayPaths.resolve(environment: [:], userHome: userHome) ? [] : ["--home", paths.home],
                               environment: environment, currentDirectory: userHome, input: Data(probe.utf8), timeout: 10)
            if r.status == 0, r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == RelayHookCommand.pass {
                lines.append("relay-hook 能运行，对没登记的会话会直接放行。")
            } else {
                ok = false
                lines.append("relay-hook 没能正常运行：\(r.brief.isEmpty ? "退出码 \(r.status)" : r.brief)")
            }
        } else {
            ok = false
            lines.append("找不到 \(exe)，请先打开 AgentRelay 让它建好程序链接。")
        }
        if let lastReport {
            lines.append("最近一次收到登记会话的钩子上报：\(Self.reportFormatter.string(from: lastReport))。说明钩子已被信任、在运行。")
        } else {
            lines.append("还没收到过登记会话的钩子上报：请确认已在 Codex 里信任这些钩子，然后让登记的 Codex 会话做一个动作（例如运行一条命令）再核对。")
        }
        return IntegrationReport(ok: ok, lines: lines)
    }

    private static let reportFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 装过钩子的项目文件夹（按配置改动记录找，还装着的才算）
    public func projectHookScopes() -> [HookScope] {
        let suffix = "/.codex/hooks.json"
        let global = hooksFile(.global)
        let files = Set(((try? store.configChanges(limit: 500)) ?? [])
            .filter { $0.platform == .codex && $0.action == .install && $0.ok && $0.target.hasSuffix(suffix) && $0.target != global }
            .map(\.target))
        return files.sorted().map { HookScope.project(String($0.dropLast(suffix.count))) }.filter {
            if case .notInstalled = hookStatus($0).state { return false }
            return true
        }
    }
}

extension Store {
    /// 最近一次收到任何登记会话的钩子上报的时间（核对钩子是否在运行用）
    public func lastHookReport() throws -> Date? {
        try locked { try db.query("SELECT MAX(updated_at) AS t FROM codex_turns").first?.date("t") }
    }
}

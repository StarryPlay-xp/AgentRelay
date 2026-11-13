import Foundation

/// 从 Codex、Claude 已有的数据里找到的项目（设计方案第 7.1 节），供“添加项目”页面勾选
public struct DiscoveredProject: Sendable, Equatable, Hashable, Identifiable {
    public let platform: Platform
    public let name: String
    /// 已规范化的目录
    public let paths: [String]
    public let source: ProjectSource
    /// 目录是否都还存在
    public let exists: Bool

    public var id: String { platform.rawValue + "|" + source.rawValue + "|" + paths.joined(separator: "|") }
}

public struct DiscoveryResult: Sendable, Equatable {
    public var projects: [DiscoveredProject]
    /// 退回第二来源等情况的说明，界面上显示
    public var notes: [String]
}

/// 只读找出两边已有的项目。只读设计方案第 7.1 节列出的字段，不读会话内容和登录凭据。
public struct ProjectDiscovery: Sendable {
    /// `~/.codex`
    public let codexHome: String
    /// `~/.claude.json`
    public let claudeConfigFile: String
    /// `~/.claude/projects`
    public let claudeProjects: String

    public init(codexHome: String, claudeConfigFile: String, claudeProjects: String) {
        self.codexHome = codexHome
        self.claudeConfigFile = claudeConfigFile
        self.claudeProjects = claudeProjects
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: String = RelayPaths.userHome()) -> ProjectDiscovery {
        let codex = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? userHome + "/.codex"
        let claudeDir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        return ProjectDiscovery(
            codexHome: RelayPaths.expandTilde(codex, userHome: userHome),
            claudeConfigFile: claudeDir.map { RelayPaths.expandTilde($0, userHome: userHome) + "/.claude.json" } ?? userHome + "/.claude.json",
            claudeProjects: RelayPaths.expandTilde(claudeDir ?? userHome + "/.claude", userHome: userHome) + "/projects")
    }

    // MARK: Codex

    /// 第一来源：Codex 桌面版的项目表；再补上项目表里没有的信任目录
    public func codex() -> DiscoveryResult {
        var notes: [String] = []
        var found: [DiscoveredProject] = []
        do {
            found = try codexProjectTable()
        } catch let e as RelayError {
            notes.append("读不了 Codex 的项目表（\(e.message)），下面只列出 config.toml 里的信任目录")
        } catch {
            notes.append("读不了 Codex 的项目表，下面只列出 config.toml 里的信任目录")
        }
        let covered = Set(found.flatMap(\.paths))
        for path in codexTrustedDirs() where !covered.contains(path) {
            found.append(make(.codex, name: (path as NSString).lastPathComponent, paths: [path], source: .codexTrusted))
        }
        return DiscoveryResult(projects: found, notes: notes)
    }

    /// 只读打开 `state_<版本>.sqlite`，只查项目编号、名称和目录（F10）
    func codexProjectTable() throws -> [DiscoveredProject] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: codexHome)) ?? []
        let dbs = names.compactMap { n -> (Int, String)? in
            guard n.hasPrefix("state_"), n.hasSuffix(".sqlite"),
                  let v = Int(n.dropFirst("state_".count).dropLast(".sqlite".count)) else { return nil }
            return (v, codexHome + "/" + n)
        }.sorted { $0.0 > $1.0 }
        guard let path = dbs.first?.1 else { throw RelayError(.internalError, "没有找到项目数据库") }
        let db = try SQLiteDatabase(path: path, readOnly: true)
        let rows = try db.query("""
        SELECT p.id AS id, p.name AS name, r.path AS path FROM projects p JOIN project_roots r ON r.project_id = p.id
        ORDER BY p.position, p.id, r.position
        """)
        var order: [String] = []
        var byID: [String: (name: String, paths: [String])] = [:]
        for r in rows {
            guard let id = r.string("id"), let name = r.string("name"), let p = r.string("path") else { continue }
            if byID[id] == nil { order.append(id); byID[id] = (name, []) }
            let n = PathMatcher.normalize(p)
            if !byID[id]!.paths.contains(n) { byID[id]!.paths.append(n) }
        }
        return order.compactMap { id in
            guard let e = byID[id], !e.paths.isEmpty else { return nil }
            return make(.codex, name: e.name, paths: e.paths, source: .codexProjects)
        }
    }

    /// 第二来源：`config.toml` 里 `[projects."<路径>"]` 段的段名（只读段名，不读别的内容）
    func codexTrustedDirs() -> [String] {
        guard let text = try? String(contentsOfFile: codexHome + "/config.toml", encoding: .utf8) else { return [] }
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("[projects.\""), l.hasSuffix("\"]") else { continue }
            let quoted = l.dropFirst("[projects.\"".count).dropLast(2)
            let path = String(quoted).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            guard path.hasPrefix("/") else { continue }
            let n = PathMatcher.normalize(path)
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    // MARK: Claude

    /// 第一来源：`~/.claude.json` 里 `projects` 下的目录（只取键）；再补上会话记录里出现、配置里没有的目录
    public func claude() -> DiscoveryResult {
        var notes: [String] = []
        var found: [DiscoveredProject] = []
        if let paths = claudeConfigDirs() {
            found = paths.map { make(.claude, name: ($0 as NSString).lastPathComponent, paths: [$0], source: .claudeConfig) }
        } else {
            notes.append("读不了 ~/.claude.json，下面只列出会话记录里出现过的目录")
        }
        let covered = Set(found.flatMap(\.paths))
        for path in claudeRecordDirs() where !covered.contains(path) {
            found.append(make(.claude, name: (path as NSString).lastPathComponent, paths: [path], source: .claudeRecords))
        }
        return DiscoveryResult(projects: found, notes: notes)
    }

    func claudeConfigDirs() -> [String]? {
        guard let data = FileManager.default.contents(atPath: claudeConfigFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let projects = obj["projects"] as? [String: Any] else { return [] }
        var out: [String] = []
        for key in projects.keys.sorted() where key.hasPrefix("/") {
            let n = PathMatcher.normalize(key)
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// 每个会话记录目录里最新的一份记录，只读开头若干行里的 `cwd`（不按目录名反推，F7）
    func claudeRecordDirs() -> [String] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: claudeProjects) else { return [] }
        var out: [String] = []
        for d in dirs.sorted() where !d.hasPrefix(".") {
            let dir = claudeProjects + "/" + d
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let newest = files.filter { $0.hasSuffix(".jsonl") }.max { a, b in
                let da = (try? fm.attributesOfItem(atPath: dir + "/" + a))?[.modificationDate] as? Date ?? .distantPast
                let db = (try? fm.attributesOfItem(atPath: dir + "/" + b))?[.modificationDate] as? Date ?? .distantPast
                return da < db
            }
            guard let newest else { continue }
            for line in SessionRecordLocator.readLines(dir + "/" + newest, maxLines: 200) {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let cwd = obj["cwd"] as? String, cwd.hasPrefix("/") else { continue }
                let n = PathMatcher.normalize(cwd)
                if !out.contains(n) { out.append(n) }
                break
            }
        }
        return out
    }

    private func make(_ platform: Platform, name: String, paths: [String], source: ProjectSource) -> DiscoveredProject {
        DiscoveredProject(platform: platform, name: name, paths: paths, source: source,
                          exists: paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }
}

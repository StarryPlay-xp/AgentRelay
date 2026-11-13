import Foundation

/// 项目是从哪里加进来的（设计方案第 7.1 节、第 17 节）
public enum ProjectSource: String, Codable, Sendable, CaseIterable {
    /// Codex 桌面版的项目表
    case codexProjects = "codex_projects"
    /// Codex 的信任目录
    case codexTrusted = "codex_trusted"
    /// `~/.claude.json` 里记的目录
    case claudeConfig = "claude_config"
    /// Claude 会话记录里的目录
    case claudeRecords = "claude_records"
    /// 手动选的文件夹
    case manual

    public var displayName: String {
        switch self {
        case .codexProjects: return "Codex 项目表"
        case .codexTrusted: return "Codex 信任目录"
        case .claudeConfig: return "Claude 配置"
        case .claudeRecords: return "Claude 会话记录"
        case .manual: return "手动添加"
        }
    }
}

public struct GroupRow: Sendable, Equatable, Identifiable, Hashable {
    public let id: Int
    public let name: String
}

public enum PathKind: String, Codable, Sendable {
    /// 主目录
    case main
    /// 附加目录（临时副本、工作副本等）
    case extra
}

public struct ProjectPathRow: Sendable, Equatable, Hashable {
    public let path: String
    public let kind: PathKind
}

public struct ProjectRow: Sendable, Equatable, Identifiable, Hashable {
    public let id: Int
    public let platform: Platform
    public let name: String
    public let source: ProjectSource
    public let groupID: Int?
    public let groupName: String?
    public let includeWorktrees: Bool
    public let enabled: Bool
    public let paths: [ProjectPathRow]

    public var mainPaths: [String] { paths.filter { $0.kind == .main }.map(\.path) }
    public var extraPaths: [String] { paths.filter { $0.kind == .extra }.map(\.path) }
}

/// 新增项目的输入
public struct NewProject: Sendable, Equatable {
    public var platform: Platform
    public var name: String
    public var source: ProjectSource
    public var groupID: Int?
    public var mainPaths: [String]
    public var extraPaths: [String]
    public var includeWorktrees: Bool
    public var enabled: Bool

    public init(platform: Platform, name: String, source: ProjectSource, groupID: Int? = nil, mainPaths: [String],
                extraPaths: [String] = [], includeWorktrees: Bool = false, enabled: Bool = true) {
        self.platform = platform
        self.name = name
        self.source = source
        self.groupID = groupID
        self.mainPaths = mainPaths
        self.extraPaths = extraPaths
        self.includeWorktrees = includeWorktrees
        self.enabled = enabled
    }
}

/// 分组、项目的增删改（应用界面用），以及从数据库生成登记表
extension Store {
    // MARK: 分组

    public func groups() throws -> [GroupRow] {
        try locked {
            try db.query("SELECT id, name FROM groups ORDER BY created_at, id").map { GroupRow(id: $0.int("id")!, name: $0.string("name")!) }
        }
    }

    @discardableResult
    public func addGroup(_ name: String, at now: Date = Date()) throws -> GroupRow {
        let n = try Self.cleanName(name, what: "分组名")
        return try locked {
            guard try db.query("SELECT 1 FROM groups WHERE name = ?", [.text(n)]).isEmpty else {
                throw RelayError(.invalidArgument, "已经有叫“\(n)”的分组了")
            }
            try db.query("INSERT INTO groups (name, created_at) VALUES (?, ?)", [.text(n), SQLValue(now)])
            let row = try db.query("SELECT id, name FROM groups WHERE name = ?", [.text(n)])[0]
            return GroupRow(id: row.int("id")!, name: row.string("name")!)
        }
    }

    public func renameGroup(id: Int, to name: String) throws {
        let n = try Self.cleanName(name, what: "分组名")
        try locked {
            guard try db.query("SELECT 1 FROM groups WHERE name = ? AND id != ?", [.text(n), .int(id)]).isEmpty else {
                throw RelayError(.invalidArgument, "已经有叫“\(n)”的分组了")
            }
            try db.query("UPDATE groups SET name = ? WHERE id = ?", [.text(n), .int(id)])
        }
    }

    /// 删除分组；组里的项目变为“未分组”（不能用，直到放进别的分组）
    public func deleteGroup(id: Int) throws {
        try locked { try db.query("DELETE FROM groups WHERE id = ?", [.int(id)]) }
    }

    // MARK: 项目

    public func projects() throws -> [ProjectRow] {
        try locked { try projectRows() }
    }

    private func projectRows() throws -> [ProjectRow] {
        let pathRows = try db.query("SELECT project_id, path, kind FROM project_paths ORDER BY kind DESC, path")
        var paths: [Int: [ProjectPathRow]] = [:]
        for r in pathRows {
            paths[r.int("project_id")!, default: []].append(
                ProjectPathRow(path: r.string("path")!, kind: PathKind(rawValue: r.string("kind")!) ?? .extra))
        }
        return try db.query("""
        SELECT p.*, g.name AS group_name FROM projects p LEFT JOIN groups g ON g.id = p.group_id ORDER BY p.created_at, p.id
        """).map { r in
            let id = r.int("id")!
            return ProjectRow(
                id: id, platform: Platform(rawValue: r.string("platform")!) ?? .codex, name: r.string("name")!,
                source: ProjectSource(rawValue: r.string("source")!) ?? .manual, groupID: r.int("group_id"),
                groupName: r.string("group_name"), includeWorktrees: r.bool("include_worktrees"), enabled: r.bool("enabled"),
                paths: paths[id] ?? [])
        }
    }

    @discardableResult
    public func addProject(_ p: NewProject, userHome: String = RelayPaths.userHome(), at now: Date = Date()) throws -> ProjectRow {
        let name = try Self.cleanName(p.name, what: "项目名")
        let main = try Self.normalizedPaths(p.mainPaths, userHome: userHome)
        guard !main.isEmpty else { throw RelayError(.invalidArgument, "项目“\(name)”至少要有一个目录") }
        let extra = try Self.normalizedPaths(p.extraPaths, userHome: userHome).filter { !main.contains($0) }
        return try locked {
            try db.transaction {
                guard try db.query("SELECT 1 FROM projects WHERE name = ?", [.text(name)]).isEmpty else {
                    throw RelayError(.invalidArgument, "已经有叫“\(name)”的项目了")
                }
                if let g = p.groupID, try db.query("SELECT 1 FROM groups WHERE id = ?", [.int(g)]).isEmpty {
                    throw RelayError(.invalidArgument, "分组不存在")
                }
                try db.query("""
                INSERT INTO projects (platform, name, source, group_id, include_worktrees, enabled, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.text(p.platform.rawValue), .text(name), .text(p.source.rawValue), p.groupID.map { .int($0) } ?? .null,
                      SQLValue(p.includeWorktrees), SQLValue(p.enabled), SQLValue(now)])
                let id = try db.query("SELECT id FROM projects WHERE name = ?", [.text(name)])[0].int("id")!
                for path in main {
                    try db.query("INSERT INTO project_paths (project_id, path, kind) VALUES (?, ?, 'main')", [.int(id), .text(path)])
                }
                for path in extra {
                    try db.query("INSERT INTO project_paths (project_id, path, kind) VALUES (?, ?, 'extra')", [.int(id), .text(path)])
                }
                return try projectRows().first { $0.id == id }!
            }
        }
    }

    public func renameProject(id: Int, to name: String) throws {
        let n = try Self.cleanName(name, what: "项目名")
        try locked {
            guard try db.query("SELECT 1 FROM projects WHERE name = ? AND id != ?", [.text(n), .int(id)]).isEmpty else {
                throw RelayError(.invalidArgument, "已经有叫“\(n)”的项目了")
            }
            try db.query("UPDATE projects SET name = ? WHERE id = ?", [.text(n), .int(id)])
        }
    }

    /// 换分组；nil 表示移出分组
    public func setProjectGroup(id: Int, groupID: Int?) throws {
        try locked {
            if let g = groupID, try db.query("SELECT 1 FROM groups WHERE id = ?", [.int(g)]).isEmpty {
                throw RelayError(.invalidArgument, "分组不存在")
            }
            try db.query("UPDATE projects SET group_id = ? WHERE id = ?", [groupID.map { .int($0) } ?? .null, .int(id)])
        }
    }

    public func setProjectEnabled(id: Int, _ enabled: Bool) throws {
        try locked { try db.query("UPDATE projects SET enabled = ? WHERE id = ?", [SQLValue(enabled), .int(id)]) }
    }

    public func setProjectIncludeWorktrees(id: Int, _ on: Bool) throws {
        try locked { try db.query("UPDATE projects SET include_worktrees = ? WHERE id = ?", [SQLValue(on), .int(id)]) }
    }

    /// 整体替换附加目录
    public func setExtraPaths(id: Int, _ paths: [String], userHome: String = RelayPaths.userHome()) throws {
        let extra = try Self.normalizedPaths(paths, userHome: userHome)
        try locked {
            try db.transaction {
                let main = try db.query("SELECT path FROM project_paths WHERE project_id = ? AND kind = 'main'", [.int(id)])
                    .compactMap { $0.string("path") }
                try db.query("DELETE FROM project_paths WHERE project_id = ? AND kind = 'extra'", [.int(id)])
                for path in extra where !main.contains(path) {
                    try db.query("INSERT INTO project_paths (project_id, path, kind) VALUES (?, ?, 'extra')", [.int(id), .text(path)])
                }
            }
        }
    }

    public func deleteProject(id: Int) throws {
        try locked { try db.query("DELETE FROM projects WHERE id = ?", [.int(id)]) }
    }

    /// 由数据库里的分组和项目生成登记表
    public func registry() throws -> Registry {
        try locked {
            let groups = try db.query("SELECT name FROM groups ORDER BY created_at, id").compactMap { $0.string("name") }
            let projects = try projectRows().map {
                Project(name: $0.name, platform: $0.platform, group: $0.groupName, enabled: $0.enabled,
                        paths: $0.mainPaths + $0.extraPaths, includeWorktrees: $0.includeWorktrees)
            }
            return Registry(groups: groups, projects: projects, codexPath: try metaValue("codex_path"))
        }
    }

    // MARK: 设置（设计方案第 16 节“设置”页）

    /// 当前上限；没存过或存的格式对不上时用默认值
    public func limits() -> Limits {
        guard let json = try? locked({ try metaValue("limits") }), let data = json.data(using: .utf8),
              let l = try? JSONDecoder().decode(Limits.self, from: data) else { return Limits() }
        return l
    }

    public func setLimits(_ l: Limits) throws {
        guard l.hopLimit >= 1, l.pairPerHour >= 1, l.totalPerHour >= 1, l.maxBodyCharacters >= 1,
              l.codexInlineMaxCharacters >= 1, l.retentionDays >= 1 else {
            throw RelayError(.invalidArgument, "各项上限都要大于 0")
        }
        let data = try JSONEncoder().encode(l)
        try locked { try setMeta("limits", String(decoding: data, as: UTF8.self)) }
    }

    /// 设置里填的 codex 程序路径（可选）
    public func codexPath() -> String? {
        (try? locked { try metaValue("codex_path") }).flatMap { $0?.isEmpty == false ? $0 : nil }
    }

    public func setCodexPath(_ path: String?) throws {
        try locked {
            if let path, !path.isEmpty { try setMeta("codex_path", path) } else {
                try db.query("DELETE FROM meta WHERE key = 'codex_path'")
            }
        }
    }

    /// 设置里填的 claude 程序位置（接入向导用；没填时自动查找，见 `ClaudeCLI.locate`）
    public func claudePath() -> String? {
        (try? locked { try metaValue("claude_path") }).flatMap { $0?.isEmpty == false ? $0 : nil }
    }

    public func setClaudePath(_ path: String?) throws {
        try locked {
            if let path, !path.isEmpty { try setMeta("claude_path", path) } else {
                try db.query("DELETE FROM meta WHERE key = 'claude_path'")
            }
        }
    }

    // MARK: 工具

    static func cleanName(_ s: String, what: String) throws -> String {
        let n = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw RelayError(.invalidArgument, "\(what)不能为空") }
        guard n.count <= 100 else { throw RelayError(.invalidArgument, "\(what)太长了") }
        return n
    }

    static func normalizedPaths(_ paths: [String], userHome: String) throws -> [String] {
        var out: [String] = []
        for raw in paths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = RelayPaths.expandTilde(trimmed, userHome: userHome)
            guard expanded.hasPrefix("/") else { throw RelayError(.invalidArgument, "目录必须是绝对路径或以 ~/ 开头") }
            let n = PathMatcher.normalize(expanded)
            if !out.contains(n) { out.append(n) }
        }
        return out
    }
}

/// 应用用的登记表来源：每次从数据库现读；读出错时保留上一次的结果并报告一次
public final class DatabaseRegistry: RegistrySource, @unchecked Sendable {
    private let store: Store
    private let lock = NSLock()
    private var last: Registry = .empty
    private var reported = false

    public init(store: Store) {
        self.store = store
    }

    public func snapshot() -> (registry: Registry, error: RelayError?) {
        lock.lock()
        defer { lock.unlock() }
        do {
            last = try store.registry()
            reported = false
            return (last, nil)
        } catch {
            let e = (error as? RelayError) ?? RelayError(.internalError, "\(error)")
            defer { reported = true }
            return (last, reported ? nil : e)
        }
    }
}

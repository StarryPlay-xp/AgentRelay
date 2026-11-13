import Darwin
import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable {
    case codex
    case claude

    /// 界面和信封里显示的名称
    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

/// 登记表文件 `registry.json` 的格式（第 2 步用它代替界面，第 3 步改存数据库）。
///
/// ```json
/// {
///   "groups": ["示例组"],
///   "projects": [
///     {"name": "项目甲", "platform": "codex", "group": "示例组", "paths": ["~/示例项目"]},
///     {"name": "项目甲-Claude", "platform": "claude", "group": "示例组", "paths": ["~/示例项目"],
///      "extraPaths": ["/private/tmp/示例副本"], "enabled": true}
///   ],
///   "codexPath": "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
/// }
/// ```
public struct RegistryFile: Codable, Sendable, Equatable {
    public var groups: [String]
    public var projects: [ProjectEntry]
    public var codexPath: String?

    public init(groups: [String], projects: [ProjectEntry], codexPath: String? = nil) {
        self.groups = groups
        self.projects = projects
        self.codexPath = codexPath
    }

    public struct ProjectEntry: Codable, Sendable, Equatable {
        public var name: String
        public var platform: Platform
        public var group: String?
        public var paths: [String]
        public var extraPaths: [String]?
        public var enabled: Bool?

        public init(name: String, platform: Platform, group: String?, paths: [String], extraPaths: [String]? = nil, enabled: Bool? = nil) {
            self.name = name
            self.platform = platform
            self.group = group
            self.paths = paths
            self.extraPaths = extraPaths
            self.enabled = enabled
        }
    }
}

/// 一个登记项目。`paths` 已规范化，含主目录和附加目录。
public struct Project: Sendable, Equatable {
    public let name: String
    public let platform: Platform
    public let group: String?
    public let enabled: Bool
    public let paths: [String]
    /// 是否包含这个仓库的 Git 工作副本（设计方案第 7.2 节）
    public let includeWorktrees: Bool

    init(name: String, platform: Platform, group: String?, enabled: Bool, paths: [String], includeWorktrees: Bool = false) {
        self.name = name
        self.platform = platform
        self.group = group
        self.enabled = enabled
        self.paths = paths
        self.includeWorktrees = includeWorktrees
    }

    /// 能用：已启用且已分组（设计方案第 7.4 节：必须选分组才能用）
    public var isUsable: Bool { enabled && group != nil }
}

/// 校验并规范化后的登记表。
public struct Registry: Sendable, Equatable {
    public let groups: [String]
    public let projects: [Project]
    public let codexPath: String?

    public static let empty = Registry(groups: [], projects: [], codexPath: nil)

    init(groups: [String], projects: [Project], codexPath: String?) {
        self.groups = groups
        self.projects = projects
        self.codexPath = codexPath
    }

    public init(file: RegistryFile, userHome: String = RelayPaths.userHome()) throws {
        var seenGroups = Set<String>()
        for g in file.groups {
            let name = g.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw RelayError(.invalidArgument, "登记表里有空的分组名") }
            guard seenGroups.insert(name).inserted else { throw RelayError(.invalidArgument, "登记表里分组重名：\(name)") }
        }
        var seenProjects = Set<String>()
        var projects: [Project] = []
        for p in file.projects {
            let name = p.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw RelayError(.invalidArgument, "登记表里有空的项目名") }
            guard seenProjects.insert(name).inserted else { throw RelayError(.invalidArgument, "登记表里项目重名：\(name)") }
            if let g = p.group, !seenGroups.contains(g) {
                throw RelayError(.invalidArgument, "项目“\(name)”的分组“\(g)”不在分组列表里")
            }
            guard !p.paths.isEmpty else { throw RelayError(.invalidArgument, "项目“\(name)”没有目录") }
            var paths: [String] = []
            for raw in p.paths + (p.extraPaths ?? []) {
                let expanded = RelayPaths.expandTilde(raw, userHome: userHome)
                guard expanded.hasPrefix("/") else {
                    throw RelayError(.invalidArgument, "项目“\(name)”的目录必须是绝对路径或以 ~/ 开头")
                }
                let n = PathMatcher.normalize(expanded)
                if !paths.contains(n) { paths.append(n) }
            }
            projects.append(Project(name: name, platform: p.platform, group: p.group, enabled: p.enabled ?? true, paths: paths))
        }
        self.groups = file.groups
        self.projects = projects
        self.codexPath = file.codexPath.map { RelayPaths.expandTilde($0, userHome: userHome) }
    }

    public static func load(path: String, userHome: String = RelayPaths.userHome()) throws -> Registry {
        guard FileManager.default.fileExists(atPath: path) else { return .empty }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
            throw RelayError(.internalError, "读不了登记表：\(error.localizedDescription)")
        }
        let file: RegistryFile
        do { file = try JSONDecoder().decode(RegistryFile.self, from: data) } catch {
            throw RelayError(.invalidArgument, "登记表格式不对：\(error)")
        }
        return try Registry(file: file, userHome: userHome)
    }

    /// 会话目录属于哪个项目：只看这个平台的项目，取最长（最具体）的匹配。
    /// 不管项目是否启用、是否分组，调用方自己判断 `isUsable`。
    public func project(for platform: Platform, containing path: String) -> Project? {
        let target = PathMatcher.normalize(path)
        var best: (project: Project, length: Int)?
        for project in projects where project.platform == platform {
            for root in project.paths where PathMatcher.isWithin(target, root: root) {
                if best == nil || root.count > best!.length { best = (project, root.count) }
            }
        }
        return best?.project
    }

    public func project(named name: String) -> Project? {
        projects.first { $0.name == name }
    }
}

/// 路径规范化和比较（设计方案第 7.3 节）。
public enum PathMatcher {
    /// 解析符号链接（`/tmp` → `/private/tmp`）、去掉 `.` 和 `..`、去末尾斜杠、统一 Unicode 写法。
    /// 路径不存在时，解析存在的最长上级目录，再接上剩余部分。
    public static func normalize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        var resolved = realpathOrNil(standardized)
        if resolved == nil {
            var head = standardized
            var tail: [String] = []
            while resolved == nil && head != "/" && !head.isEmpty {
                tail.insert((head as NSString).lastPathComponent, at: 0)
                head = (head as NSString).deletingLastPathComponent
                resolved = realpathOrNil(head)
            }
            if let r = resolved {
                resolved = tail.reduce(r) { ($0 as NSString).appendingPathComponent($1) }
            }
        }
        var result = resolved ?? standardized
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result.precomposedStringWithCanonicalMapping
    }

    /// `path` 等于 `root` 或位于其下（两者都应已规范化）
    public static func isWithin(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }

    private static func realpathOrNil(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// 登记表的来源：第 2 步是 JSON 文件（`RegistryStore`），应用里是数据库（`DatabaseRegistry`）。
public protocol RegistrySource: Sendable {
    /// 返回最新的登记表；`error` 是这次读取遇到的问题（如果有），只报告一次
    func snapshot() -> (registry: Registry, error: RelayError?)
}

/// 登记表文件改了就自动重读；读坏了保留上一次的内容，并把错误交给调用方记录。
public final class RegistryStore: RegistrySource, @unchecked Sendable {
    private let path: String
    private let userHome: String
    private let lock = NSLock()
    private var current: Registry = .empty
    private var stamp: (mtime: timespec, size: off_t)?
    private var lastError: RelayError?

    public init(path: String, userHome: String = RelayPaths.userHome()) {
        self.path = path
        self.userHome = userHome
    }

    /// 返回最新的登记表；`error` 是这次重读遇到的问题（如果有），只报告一次。
    public func snapshot() -> (registry: Registry, error: RelayError?) {
        lock.lock()
        defer { lock.unlock() }
        var st = stat()
        let exists = stat(path, &st) == 0
        let newStamp = exists ? (st.st_mtimespec, st.st_size) : nil
        let changed: Bool
        switch (stamp, newStamp) {
        case (nil, nil): changed = false
        case let (old?, new?): changed = old.mtime.tv_sec != new.0.tv_sec || old.mtime.tv_nsec != new.0.tv_nsec || old.size != new.1
        default: changed = true
        }
        var reported: RelayError?
        if changed {
            stamp = newStamp.map { (mtime: $0.0, size: $0.1) }
            do {
                current = try Registry.load(path: path, userHome: userHome)
                lastError = nil
            } catch let e as RelayError {
                lastError = e
                reported = e
            } catch {
                let e = RelayError(.internalError, "\(error)")
                lastError = e
                reported = e
            }
        }
        return (current, reported)
    }
}

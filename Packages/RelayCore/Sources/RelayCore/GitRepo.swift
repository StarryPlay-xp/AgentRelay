import Foundation

/// 认出 Git 工作副本（worktree）属于哪个仓库：只读 `.git` 目录或文件，不运行 git。
public enum GitRepo {
    /// 从 `path` 往上找 `.git`，返回仓库的共用目录（同一仓库的主目录和所有工作副本相同）；不在 Git 仓库里返回 nil
    public static func commonDir(containing path: String) -> String? {
        let fm = FileManager.default
        var dir = PathMatcher.normalize(path)
        while true {
            let dotGit = dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                if isDir.boolValue { return PathMatcher.normalize(dotGit) }
                return commonDir(fromGitFile: dotGit, base: dir)
            }
            if dir == "/" || dir.isEmpty { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    /// 工作副本里的 `.git` 是个文件：`gitdir: <仓库>/.git/worktrees/<名字>`；那里的 `commondir` 指回共用目录
    static func commonDir(fromGitFile file: String, base: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitDir.hasPrefix("/") { gitDir = base + "/" + gitDir }
        gitDir = PathMatcher.normalize(gitDir)
        if let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) {
            var c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.hasPrefix("/") { c = gitDir + "/" + c }
            return PathMatcher.normalize(c)
        }
        return gitDir
    }
}

import Foundation
import Testing
@testable import RelayCore

@Suite("接入：Codex 钩子（立即引导）")
struct HookIntegrationTests {
    func harness() throws -> IntegrationHarness {
        let h = try IntegrationHarness()
        try "#!/bin/sh\necho '{}'\n".write(toFile: h.paths.bin + "/relay-hook", atomically: true, encoding: .utf8)
        chmod(h.paths.bin + "/relay-hook", 0o755)
        return h
    }

    func json(_ path: String) throws -> [String: Any] {
        let data = try #require(FileManager.default.contents(atPath: path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("全局：没有 hooks.json → 装上 5 条 → 再装不重复 → 装后没改过时卸载删掉文件")
    func globalCleanInstall() throws {
        let h = try harness()
        let i = h.integrations!
        let file = h.codexHome + "/hooks.json"
        #expect(i.hooksFile(.global) == file)
        #expect(i.hookCommand == "\(h.paths.bin)/relay-hook --home \(h.paths.home)")
        #expect(i.hookStatus(.global).state == .notInstalled)
        #expect(i.hookPreview(.global).notes.contains { $0.contains("不会替你写信任记录") })

        let r = i.installHooks(.global)
        #expect(r.ok, "\(r.lines)")
        #expect(r.lines.contains { $0.contains("请在 Codex 里信任") })
        #expect(i.hookStatus(.global).state == .installed)
        let obj = try json(file)
        let hooks = try #require(obj["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(Integrations.hookEvents))
        let pre = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        #expect(pre["matcher"] as? String == "*")
        let handler = try #require((pre["hooks"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "command")
        #expect(handler["command"] as? String == i.hookCommand)
        #expect(handler["timeout"] as? Int == Integrations.hookTimeout)
        #expect((hooks["Stop"] as? [[String: Any]])?.first?["matcher"] == nil)

        #expect(i.installHooks(.global).lines.contains { $0.contains("已经装好了") })
        #expect(try h.store.configChanges().filter { $0.target == file }.count == 1)

        let u = i.uninstallHooks(.global)
        #expect(u.ok, "\(u.lines)")
        #expect(!FileManager.default.fileExists(atPath: file), "安装时新建的文件，装后没改过就删掉")
        #expect(u.lines.contains { $0.contains("设置 › Hooks") })
        #expect(i.hookStatus(.global).state == .notInstalled)
        // Codex 的 config.toml 安装记录不受钩子记录影响
        #expect(try h.store.lastInstall(platform: .codex, target: h.codexFile) == nil)
    }

    @Test("已有别人的钩子：只加我们的，卸载时只删我们的；文件装后被改过就按条删，别的钩子和别的数据目录的 relay-hook 都保留")
    func mergeWithExisting() throws {
        let h = try harness()
        let i = h.integrations!
        let file = h.codexHome + "/hooks.json"
        let other = "'/opt/另一份/.agentrelay/bin/relay-hook'"
        let original: [String: Any] = ["hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/audit"]]]],
            "Stop": [["hooks": [["type": "command", "command": other]]]],
        ]]
        try JSONSerialization.data(withJSONObject: original).write(to: URL(fileURLWithPath: file))
        #expect(i.hookStatus(.global).state == .notInstalled)
        #expect(i.hookStatus(.global).others == [other])

        #expect(i.installHooks(.global).ok)
        let backup = try #require(try h.store.lastInstall(platform: .codex, target: file)?.backupPath)
        #expect(FileManager.default.contents(atPath: backup) == (try JSONSerialization.data(withJSONObject: original)))
        let pre = try #require((try json(file)["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 2, "原有的那组保留，我们的另加一组")

        // 装后又被别的程序改了：不能逐字还原，只删我们的
        var changed = try json(file)
        changed["extra"] = true
        try JSONSerialization.data(withJSONObject: changed).write(to: URL(fileURLWithPath: file))
        let u = i.uninstallHooks(.global)
        #expect(u.ok, "\(u.lines)")
        #expect(u.lines.contains { $0.contains("已移除 5 条钩子") })
        let after = try json(file)
        #expect(after["extra"] as? Bool == true)
        let hooks = try #require(after["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["PreToolUse", "Stop"])
        #expect(((hooks["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/local/bin/audit")
        #expect(i.hookStatus(.global).others == [other])
    }

    @Test("项目文件夹：只写 <项目>/.codex/hooks.json；列在装过的项目里；卸载后删掉空的 .codex")
    func projectScope() throws {
        let h = try harness()
        let i = h.integrations!
        let project = h.t.path + "/测试项目"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let scope = HookScope.project(project)
        #expect(i.hooksFile(scope) == project + "/.codex/hooks.json")
        #expect(i.installHooks(.project(h.t.path + "/不存在")).ok == false)
        #expect(i.installHooks(scope).ok)
        #expect(!FileManager.default.fileExists(atPath: h.codexHome + "/hooks.json"), "不碰全局")
        #expect(i.projectHookScopes() == [scope])
        #expect(i.uninstallHooks(scope).ok)
        #expect(!FileManager.default.fileExists(atPath: project + "/.codex"))
        #expect(i.projectHookScopes().isEmpty)
    }

    @Test("看不懂的 hooks.json 不碰；没有 relay-hook 程序不装；核对说明还没收到上报")
    func guards() throws {
        let h = try harness()
        let i = h.integrations!
        let file = h.codexHome + "/hooks.json"
        try "不是 JSON".write(toFile: file, atomically: true, encoding: .utf8)
        if case .unknown = i.hookStatus(.global).state {} else { Issue.record("应当是看不懂") }
        #expect(!i.installHooks(.global).ok)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "不是 JSON")
        try FileManager.default.removeItem(atPath: file)
        try FileManager.default.removeItem(atPath: h.paths.bin + "/relay-hook")
        #expect(!i.installHooks(.global).ok)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test("完全卸载：先移除钩子再移除传话工具")
    func fullUninstallRemovesHooks() throws {
        let h = try harness()
        let i = h.integrations!
        #expect(i.installHooks(.global).ok)
        let steps = FullUninstall.removeIntegrations(i)
        #expect(steps.first?.title.contains("移除 Codex 钩子") == true)
        #expect(steps.allSatisfy { $0.ok }, "\(steps)")
        #expect(i.hookStatus(.global).state == .notInstalled)
    }
}

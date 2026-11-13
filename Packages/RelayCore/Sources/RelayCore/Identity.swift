import Foundation

/// relay-mcp 收集到的调用方信息（设计方案第 5.2 节），随每次请求发给中转核心。
public struct CallerInfo: Codable, Sendable, Equatable {
    /// relay-mcp 自己的工作目录（两边都是会话目录，F14、F16）
    public var cwd: String
    /// Codex：这次调用请求里的 `_meta.threadId`（F15）
    public var codexThreadID: String?
    /// Claude：relay-mcp 进程环境里的 `CLAUDE_CODE_SESSION_ID`（F16）
    public var claudeSessionID: String?
    /// Claude：`CLAUDE_CODE_HOST_SESSION_ID`（桌面版的 `local_…` 编号，只用于显示）
    public var claudeHostSessionID: String?
    /// 会话自报的编号（只作核对）
    public var selfReportedSessionID: String?
    /// MCP 握手里客户端报的名称和版本
    public var clientName: String?
    public var clientVersion: String?

    public init(cwd: String, codexThreadID: String? = nil, claudeSessionID: String? = nil,
                claudeHostSessionID: String? = nil, selfReportedSessionID: String? = nil,
                clientName: String? = nil, clientVersion: String? = nil) {
        self.cwd = cwd
        self.codexThreadID = codexThreadID
        self.claudeSessionID = claudeSessionID
        self.claudeHostSessionID = claudeHostSessionID
        self.selfReportedSessionID = selfReportedSessionID
        self.clientName = clientName
        self.clientVersion = clientVersion
    }
}

/// 核对通过的调用方身份
public struct CallerIdentity: Sendable, Equatable {
    public let platform: Platform
    public let sessionID: String
    public let hostSessionID: String?
    public let source: IdentitySource
    public let record: SessionRecord
    public let project: Project
}

/// 身份核对（设计方案第 8.1 节）
public struct IdentityResolver: Sendable {
    public let locator: SessionRecordLocating

    public init(locator: SessionRecordLocating) {
        self.locator = locator
    }

    /// - Parameters:
    ///   - caller: relay-mcp 报来的调用方信息
    ///   - peerPlatform: 按父进程签名认出的平台；放宽检查（开发、测试）时为 nil，改从调用方信息推断
    ///   - registry: 当前登记表
    public func resolve(_ caller: CallerInfo, peerPlatform: Platform?, registry: Registry) throws -> CallerIdentity {
        let platform = try peerPlatform ?? inferPlatform(caller)

        // 1. 编号从哪来：可靠来源优先，自报只作核对
        let trusted: (id: String, source: IdentitySource)?
        switch platform {
        case .codex: trusted = caller.codexThreadID.flatMap { $0.isEmpty ? nil : ($0, .meta) }
        case .claude: trusted = caller.claudeSessionID.flatMap { $0.isEmpty ? nil : ($0, .env) }
        }
        let selfReported = caller.selfReportedSessionID.flatMap { $0.isEmpty ? nil : $0 }
        let sessionID: String
        let source: IdentitySource
        if let trusted {
            if let selfReported, selfReported.lowercased() != trusted.id.lowercased() {
                throw RelayError(.identityMismatch, "会话自报的编号和 \(platform.displayName) 给出的编号不一致")
            }
            sessionID = trusted.id
            source = trusted.source
        } else if let selfReported {
            sessionID = selfReported
            source = .selfReported
        } else {
            throw RelayError(.identityMismatch, "拿不到本会话的编号。Codex 读环境变量 CODEX_THREAD_ID，Claude 读 CLAUDE_CODE_SESSION_ID，作为 session_id 传入")
        }
        guard SessionRecordLocator.isValidSessionID(sessionID) else {
            throw RelayError(.identityMismatch, "会话编号格式不对")
        }

        // 2. 编号存不存在
        guard let record = locator.find(platform: platform, sessionID: sessionID) else {
            throw RelayError(.identityMismatch, "本机找不到这个 \(platform.displayName) 会话的记录")
        }

        // 3. 目录对不对：记录里的目录要落在能用的登记项目里，并和 relay-mcp 的工作目录一致
        let recordCwd = PathMatcher.normalize(record.cwd)
        guard let project = registry.project(for: platform, containing: recordCwd) else {
            throw RelayError(.projectNotRegistered, "这个会话的目录不在任何登记的 \(platform.displayName) 项目里")
        }
        guard project.isUsable else {
            throw RelayError(.projectNotRegistered, "项目“\(project.name)”已停用或还没分组")
        }
        if !caller.cwd.isEmpty, PathMatcher.normalize(caller.cwd) != recordCwd {
            throw RelayError(.identityMismatch, "调用方的工作目录和会话记录里的目录对不上")
        }
        let host = platform == .claude ? caller.claudeHostSessionID.flatMap { $0.isEmpty ? nil : $0 } : nil
        return CallerIdentity(platform: platform, sessionID: sessionID.lowercased(), hostSessionID: host,
                              source: source, record: SessionRecord(platform: platform, sessionID: record.sessionID, cwd: recordCwd),
                              project: project)
    }

    /// 放宽检查时按调用方信息推断平台
    func inferPlatform(_ c: CallerInfo) throws -> Platform {
        if c.codexThreadID?.isEmpty == false { return .codex }
        if c.claudeSessionID?.isEmpty == false { return .claude }
        let name = (c.clientName ?? "").lowercased()
        if name.contains("codex") { return .codex }
        if name.contains("claude") { return .claude }
        throw RelayError(.identityMismatch, "认不出调用方是 Codex 还是 Claude")
    }
}

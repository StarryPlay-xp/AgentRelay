import Foundation

/// relay-mcp ↔ 中转核心的通信格式（设计方案第 15 节）：带版本号的 JSON，一行一条，一个连接一问一答。
public enum Wire {
    public static let version = 1
    /// 单条请求或回复的最大字节数
    public static let maxLineBytes = 1 << 20
}

public enum WireOp: String, Codable, Sendable {
    case register, contacts, send, inbox, status
    /// relay-hook 上报 Codex 钩子事件（只允许 relay-hook 调用，见 PeerCheck）
    case hook
}

/// relay-hook 从 Codex 钩子输入里取出的几项。只带这几项：不带用户输入的文字、命令内容和工具参数。
public struct HookEvent: Codable, Sendable, Equatable {
    /// `hook_event_name`：UserPromptSubmit、PreToolUse、PostToolUse、Stop、Interrupt
    public var event: String
    /// `session_id`：Codex 会话编号
    public var sessionID: String
    /// `turn_id`：这一轮的编号
    public var turnID: String?
    /// `tool_name`：PreToolUse、PostToolUse 才有
    public var toolName: String?
    /// `stop_hook_active`：Stop 才有，本轮已经被结束钩子续过一次时为真
    public var stopHookActive: Bool?

    public init(event: String, sessionID: String, turnID: String? = nil, toolName: String? = nil, stopHookActive: Bool? = nil) {
        self.event = event
        self.sessionID = sessionID
        self.turnID = turnID
        self.toolName = toolName
        self.stopHookActive = stopHookActive
    }
}

public struct WireArgs: Codable, Sendable, Equatable {
    public var mailbox: String?
    public var to: String?
    public var body: String?
    public var replyTo: String?
    public var needsReply: Bool?
    public var subject: String?
    public var markRead: Bool?
    /// relay_send：投递方式，默认排队
    public var delivery: DeliveryMode?
    /// relay_send：立即引导送不进去时怎么办，默认不降级
    public var steerFallback: SteerFallback?
    /// relay-hook 上报的钩子事件
    public var hook: HookEvent?

    public init(mailbox: String? = nil, to: String? = nil, body: String? = nil, replyTo: String? = nil,
                needsReply: Bool? = nil, subject: String? = nil, markRead: Bool? = nil,
                delivery: DeliveryMode? = nil, steerFallback: SteerFallback? = nil, hook: HookEvent? = nil) {
        self.mailbox = mailbox
        self.to = to
        self.body = body
        self.replyTo = replyTo
        self.needsReply = needsReply
        self.subject = subject
        self.markRead = markRead
        self.delivery = delivery
        self.steerFallback = steerFallback
        self.hook = hook
    }
}

public struct WireRequest: Codable, Sendable, Equatable {
    public var v: Int
    public var token: String
    public var op: WireOp
    public var caller: CallerInfo
    public var args: WireArgs

    public init(v: Int = Wire.version, token: String, op: WireOp, caller: CallerInfo, args: WireArgs = WireArgs()) {
        self.v = v
        self.token = token
        self.op = op
        self.caller = caller
        self.args = args
    }
}

public struct ContactInfo: Codable, Sendable, Equatable {
    public var mailbox: String
    public var platform: Platform
    public var project: String
    /// Claude：是否正在等信；Codex 不需要等信，为 nil
    public var waiting: Bool?
}

public struct InboxMessage: Codable, Sendable, Equatable {
    public var id: String
    public var from: String
    /// 信封加正文
    public var text: String
}

/// 回复的内容。`text` 是给会话看的中文说明，其他字段便于程序处理和测试。
public struct WireResult: Codable, Sendable, Equatable {
    public var text: String
    public var mailbox: String?
    public var group: String?
    public var project: String?
    public var contacts: [ContactInfo]?
    public var waitCommand: String?
    public var messageID: String?
    public var chainID: String?
    public var hop: Int?
    public var delivery: MessageStatus?
    public var messages: [InboxMessage]?
    public var unread: Int?
    /// relay_send：发信方要求的投递方式
    public var requestedDelivery: DeliveryMode?
    /// relay_send：实际采用的投递方式（立即引导要等注入后才确定，见 relay_status）
    public var actualDelivery: DeliveryMode?
    /// relay-hook：要打印给 Codex 的钩子输出（JSON 文本）；nil 表示放行、不注入
    public var hookOutput: String?

    public init(text: String) { self.text = text }
}

public struct WireError: Codable, Sendable, Equatable {
    public var code: RelayErrorCode
    public var message: String
}

public struct WireResponse: Codable, Sendable, Equatable {
    public var v: Int
    public var ok: Bool
    public var result: WireResult?
    public var error: WireError?

    public static func success(_ r: WireResult) -> WireResponse {
        WireResponse(v: Wire.version, ok: true, result: r, error: nil)
    }

    public static func failure(_ e: RelayError) -> WireResponse {
        WireResponse(v: Wire.version, ok: false, result: nil, error: WireError(code: e.code, message: e.message))
    }
}

import Foundation

/// relay-mcp ↔ 中转核心的通信格式（设计方案第 15 节）：带版本号的 JSON，一行一条，一个连接一问一答。
public enum Wire {
    public static let version = 1
    /// 单条请求或回复的最大字节数
    public static let maxLineBytes = 1 << 20
}

public enum WireOp: String, Codable, Sendable {
    case register, contacts, send, inbox, status
}

public struct WireArgs: Codable, Sendable, Equatable {
    public var mailbox: String?
    public var to: String?
    public var body: String?
    public var replyTo: String?
    public var needsReply: Bool?
    public var subject: String?
    public var markRead: Bool?

    public init(mailbox: String? = nil, to: String? = nil, body: String? = nil, replyTo: String? = nil,
                needsReply: Bool? = nil, subject: String? = nil, markRead: Bool? = nil) {
        self.mailbox = mailbox
        self.to = to
        self.body = body
        self.replyTo = replyTo
        self.needsReply = needsReply
        self.subject = subject
        self.markRead = markRead
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

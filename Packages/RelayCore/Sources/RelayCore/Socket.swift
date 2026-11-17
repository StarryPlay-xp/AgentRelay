import Darwin
import Foundation

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw RelayError(.internalError, "本机通话口路径太长")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 读一行（不含换行），超过上限或超时返回 nil
    static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= limit {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return data.isEmpty ? nil : data }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buf[0..<nl])
                return data
            }
            data.append(contentsOf: buf[0..<n])
        }
        return nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}

/// 中转核心一侧的本机通话口（设计方案第 15 节）：只在本机文件系统里，不开网络端口；
/// 文件 0600；每个连接先核对对端，再核对暗号和版本。
public final class SocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (WireRequest, Platform?) -> WireResponse

    private let paths: RelayPaths
    private let policy: PeerPolicy
    private let handler: Handler
    private let onReject: @Sendable (String) -> Void
    private var listenFD: Int32 = -1
    private var token = ""
    private let lock = NSLock()
    private var running = false

    public init(paths: RelayPaths, policy: PeerPolicy, onReject: @escaping @Sendable (String) -> Void = { _ in },
                handler: @escaping Handler) {
        self.paths = paths
        self.policy = policy
        self.handler = handler
        self.onReject = onReject
    }

    /// 生成新暗号、开始监听
    public func start() throws {
        try paths.prepare()
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RelayError(.internalError, "生成暗号失败")
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        try FileSystem.writeAtomically(Data(token.utf8), to: paths.token)

        unlink(paths.socket)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError(.internalError, "建不了本机通话口") }
        var addr = try UnixSocket.address(paths.socket)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw RelayError(.internalError, "本机通话口绑定失败：\(String(cString: strerror(errno)))")
        }
        chmod(paths.socket, 0o600)
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw RelayError(.internalError, "本机通话口监听失败")
        }
        lock.lock()
        listenFD = fd
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "agentrelay.accept"
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        running = false
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(paths.socket)
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if !isRunning { return }
                continue
            }
            // 每个连接一个独立线程：处理中会同步等待（例如运行 codex queue），不占 GCD 全局线程池
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        UnixSocket.setTimeout(fd, seconds: 30)
        let response: WireResponse
        do {
            let peer = try PeerCheck.peer(of: fd)
            let platform: Platform?
            do {
                platform = try PeerCheck.verify(peer, policy: policy)
            } catch let e as RelayError {
                onReject("拒绝连接：\(e.message)（对端进程 \(peer.pid)）")
                throw e
            }
            guard let line = UnixSocket.readLine(fd, limit: Wire.maxLineBytes) else {
                throw RelayError(.invalidArgument, "请求为空或太长")
            }
            let request: WireRequest
            do { request = try JSONDecoder().decode(WireRequest.self, from: line) } catch {
                if let v = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["v"] as? Int, v != Wire.version {
                    throw RelayError(.versionMismatch, "relay-mcp 和中转核心版本不一致，请更新 AgentRelay")
                }
                throw RelayError(.invalidArgument, "请求格式不对")
            }
            guard request.v == Wire.version else {
                throw RelayError(.versionMismatch, "relay-mcp 和中转核心版本不一致，请更新 AgentRelay")
            }
            guard constantTimeEqual(request.token, token) else {
                onReject("拒绝请求：暗号不对（对端进程 \(peer.pid)）")
                throw RelayError(.identityMismatch, "暗号不对")
            }
            response = handler(request, platform)
        } catch let e as RelayError {
            response = .failure(e)
        } catch {
            response = .failure(RelayError(.internalError, "\(error)"))
        }
        if var data = try? JSONEncoder().encode(response) {
            data.append(0x0A)
            _ = UnixSocket.writeAll(fd, data)
        }
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// relay-mcp 一侧：连中转核心，发一条请求，收一条回复
public enum SocketClient {
    public static func send(op: WireOp, caller: CallerInfo, args: WireArgs, paths: RelayPaths, timeout: Int = 60) -> WireResponse {
        guard let token = try? String(contentsOfFile: paths.token, encoding: .utf8), !token.isEmpty else {
            return .failure(RelayError(.relayNotRunning, "AgentRelay 没在运行（找不到暗号文件）"))
        }
        let request = WireRequest(token: token.trimmingCharacters(in: .whitespacesAndNewlines), op: op, caller: caller, args: args)
        do {
            return try exchange(request, socketPath: paths.socket, timeout: timeout)
        } catch let e as RelayError {
            return .failure(e)
        } catch {
            return .failure(RelayError(.internalError, "\(error)"))
        }
    }

    public static func exchange(_ request: WireRequest, socketPath: String, timeout: Int) throws -> WireResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError(.internalError, "建不了连接") }
        defer { close(fd) }
        UnixSocket.setTimeout(fd, seconds: timeout)
        var addr = try UnixSocket.address(socketPath)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED {
                throw RelayError(.relayNotRunning, "AgentRelay 没在运行，请先打开 AgentRelay")
            }
            throw RelayError(.relayNotRunning, "连不上 AgentRelay：\(String(cString: strerror(errno)))")
        }
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        guard UnixSocket.writeAll(fd, data) else { throw RelayError(.relayNotRunning, "发送请求失败") }
        guard let line = UnixSocket.readLine(fd, limit: Wire.maxLineBytes) else {
            throw RelayError(.relayNotRunning, "AgentRelay 没有回应")
        }
        do { return try JSONDecoder().decode(WireResponse.self, from: line) } catch {
            throw RelayError(.versionMismatch, "看不懂 AgentRelay 的回应，可能版本不一致")
        }
    }
}

/// 单实例锁：同一个 AGENTRELAY_HOME 只能有一个中转核心在运行
public final class InstanceLock: @unchecked Sendable {
    private let fd: Int32

    public init(path: String) throws {
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw RelayError(.internalError, "打不开单实例锁") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw RelayError(.internalError, "已经有一个中转核心在运行")
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

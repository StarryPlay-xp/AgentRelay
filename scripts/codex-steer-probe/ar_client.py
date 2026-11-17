"""最小 Codex App Server 客户端：支持 stdio（自己拉起 app-server）和 unix 套接字上的 WebSocket。

只用标准库。每条收到的消息都带接收时间，方便核对先后顺序。
"""
import base64, json, os, socket, struct, subprocess, threading, time


class Client:
    def __init__(self, name):
        self.name = name
        self.next_id = 1
        self.pending = {}
        self.events = []          # (时间, 消息) 全部通知和服务器请求
        self.cv = threading.Condition()
        self.server_request_handler = None  # fn(msg) -> result | None（None 表示不回应）
        self.closed = False

    # ---- 传输层由子类实现 ----
    def _send_raw(self, obj):
        raise NotImplementedError

    def _on_message(self, msg):
        now = time.time()
        with self.cv:
            if "id" in msg and ("result" in msg or "error" in msg) and "method" not in msg:
                self.pending[msg["id"]] = (now, msg)
            else:
                self.events.append((now, msg))
            self.cv.notify_all()
        if "method" in msg and "id" in msg and self.server_request_handler:
            res = self.server_request_handler(msg)
            if res is not None:
                self._send_raw({"id": msg["id"], "result": res})

    def send_request(self, method, params):
        rid = self.next_id
        self.next_id += 1
        t = time.time()
        self._send_raw({"id": rid, "method": method, "params": params})
        return rid, t

    def wait_response(self, rid, timeout=60):
        deadline = time.time() + timeout
        with self.cv:
            while rid not in self.pending:
                left = deadline - time.time()
                if left <= 0 or self.closed:
                    raise TimeoutError(f"{self.name}: no response for id {rid}")
                self.cv.wait(left)
            return self.pending.pop(rid)

    def request(self, method, params, timeout=60):
        rid, t = self.send_request(method, params)
        t_resp, msg = self.wait_response(rid, timeout)
        return {"sent": t, "received": t_resp, "msg": msg}

    def notify(self, method, params=None):
        m = {"method": method}
        if params is not None:
            m["params"] = params
        self._send_raw(m)

    def wait_event(self, pred, timeout=60, start_index=0):
        deadline = time.time() + timeout
        with self.cv:
            i = start_index
            while True:
                while i < len(self.events):
                    t, m = self.events[i]
                    if pred(m):
                        return i, t, m
                    i += 1
                left = deadline - time.time()
                if left <= 0:
                    raise TimeoutError(f"{self.name}: event not seen")
                self.cv.wait(left)

    def initialize(self, experimental=True):
        r = self.request("initialize", {
            "clientInfo": {"name": "agentrelay_steer_probe", "title": "AgentRelay steer probe", "version": "0.0.1"},
            "capabilities": {"experimentalApi": experimental},
        })
        self.notify("initialized")
        return r


class StdioClient(Client):
    def __init__(self, name, codex_bin, codex_home, cwd, extra_args=(), stderr_path=None):
        super().__init__(name)
        env = dict(os.environ)
        env["CODEX_HOME"] = codex_home
        env.pop("CODEX_THREAD_ID", None)
        env.pop("CODEX_SESSION_ID", None)
        self.stderr_f = open(stderr_path or os.devnull, "ab")
        self.proc = subprocess.Popen([codex_bin, "app-server", *extra_args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.stderr_f, cwd=cwd, env=env)
        self.wlock = threading.Lock()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self._on_message(json.loads(line))
            except json.JSONDecodeError:
                pass
        with self.cv:
            self.closed = True
            self.cv.notify_all()

    def _send_raw(self, obj):
        with self.wlock:
            self.proc.stdin.write((json.dumps(obj) + "\n").encode())
            self.proc.stdin.flush()

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.terminate()


class UnixWsClient(Client):
    """WebSocket over Unix domain socket（与桌面端连 daemon 的方式相同：ws://localhost/rpc）"""

    def __init__(self, name, sock_path, path="/rpc"):
        super().__init__(name)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(sock_path)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("handshake closed")
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise ConnectionError(f"handshake failed: {status!r}")
        self.buf = rest
        self.wlock = threading.Lock()
        threading.Thread(target=self._reader, daemon=True).start()

    def _recv_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _reader(self):
        frag = b""
        try:
            while True:
                b0, b1 = self._recv_exact(2)
                fin, op = b0 & 0x80, b0 & 0x0F
                ln = b1 & 0x7F
                if ln == 126:
                    ln = struct.unpack(">H", self._recv_exact(2))[0]
                elif ln == 127:
                    ln = struct.unpack(">Q", self._recv_exact(8))[0]
                mask = self._recv_exact(4) if b1 & 0x80 else None
                data = self._recv_exact(ln)
                if mask:
                    data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
                if op == 8:
                    break
                if op == 9:
                    self._send_frame(10, data)
                    continue
                if op in (0, 1, 2):
                    frag += data
                    if fin:
                        try:
                            self._on_message(json.loads(frag))
                        except json.JSONDecodeError:
                            pass
                        frag = b""
        except (ConnectionError, OSError):
            pass
        with self.cv:
            self.closed = True
            self.cv.notify_all()

    def _send_frame(self, op, payload):
        hdr = bytearray([0x80 | op])
        n = len(payload)
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126); hdr += struct.pack(">H", n)
        else:
            hdr.append(0x80 | 127); hdr += struct.pack(">Q", n)
        mask = os.urandom(4)
        hdr += mask
        body = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        with self.wlock:
            self.sock.sendall(bytes(hdr) + body)

    def _send_raw(self, obj):
        self._send_frame(1, json.dumps(obj).encode())

    def close(self, abrupt=False):
        try:
            if not abrupt:
                self._send_frame(8, b"")
            self.sock.close()
        except OSError:
            pass


def text_input(text):
    return [{"type": "text", "text": text}]

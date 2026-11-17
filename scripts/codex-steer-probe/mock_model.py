#!/usr/bin/env python3
"""本地假模型服务：模拟 Responses API 的 SSE 流式接口，只用于隔离测试 Codex App Server。

不联网、不需要任何账号。根据“本次请求里第一次出现的用户文字”决定怎么回：
- 含 SLOW=<秒>       ：先发 response.created，等这么多秒再回文字（模拟模型在长时间思考）
- 含 TOOL_SLEEP=<秒> ：让 Codex 调用 exec_command 执行 `sleep <秒>`（模拟正在执行命令）
- 含 SLOWTOOL=<秒>   ：先“思考”这么多秒，再让 Codex 执行 `echo STEP2-RAN`（模拟想好下一步、正要执行命令）
- 含 NEED_APPROVAL   ：让 Codex 以提权方式执行一条命令，从而触发审批请求
- 含 MARK-xxx        ：回复 “ACK MARK-xxx …”，证明模型这一轮确实读到了这些标记
- 其他                ：回复 DONE（工具结果之后回 DONE-TOOL）
每个请求都写进日志（时间、x-codex 开头的请求头、新出现的用户文字、回复类型）。
注意：判断“新文字”靠全文比对，同一段任务文字第二次出现就不算新的，所以每个任务文字要唯一。
"""
import json, re, sys, threading, time, gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_PATH = sys.argv[2] if len(sys.argv) > 2 else "/tmp/ar-mock-requests.jsonl"
SEEN = set()
SEEN_LOCK = threading.Lock()
LOG_LOCK = threading.Lock()
COUNTER = [0]


def log(entry):
    with LOG_LOCK:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def tool_output_text(it):
    o = it.get("output")
    if isinstance(o, str):
        return o
    if isinstance(o, list):
        return "".join(c.get("text", "") for c in o if isinstance(c, dict))
    return ""


def user_texts(items):  # 用户消息、开发者消息（钩子的 additionalContext）和工具结果（命令被钩子拦下时的理由）
    out = []
    for it in items:
        if it.get("type") == "message" and it.get("role") in ("user", "developer"):
            for c in it.get("content") or []:
                if c.get("type") in ("input_text", "text"):
                    out.append(c.get("text", ""))
        elif it.get("type") in ("function_call_output", "custom_tool_call_output"):
            out.append(tool_output_text(it))
    return out


def has_trailing_tool_output(items):
    for it in reversed(items):
        t = it.get("type")
        if t in ("function_call_output", "custom_tool_call_output"):
            return True
        if t == "message":
            return False
    return False


def ev(kind, **kw):
    d = {"type": kind}
    d.update(kw)
    return f"event: {kind}\ndata: {json.dumps(d)}\n\n".encode()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        enc = (self.headers.get("Content-Encoding") or "").lower()
        if enc == "gzip":
            raw = gzip.decompress(raw)
        elif enc == "zstd":
            from compression import zstd  # Python 3.14+
            raw = zstd.decompress(raw)
        if not self.path.endswith("/responses"):
            log({"t": time.time(), "path": self.path, "note": "ignored"})
            self.send_response(404)
            self.end_headers()
            return
        body = json.loads(raw or b"{}")
        items = body.get("input") or []
        texts = user_texts(items)
        with SEEN_LOCK:
            new = [t for t in texts if t not in SEEN]
            SEEN.update(texts)
            COUNTER[0] += 1
            req_no = COUNTER[0]
        joined = "\n".join(new)
        marks = re.findall(r"MARK-[A-Za-z0-9_-]+", joined)
        slow = re.search(r"SLOW=(\d+(?:\.\d+)?)", joined)
        tool_sleep = re.search(r"TOOL_SLEEP=(\d+)", joined)
        slow_tool = re.search(r"SLOWTOOL=(\d+(?:\.\d+)?)", joined)
        need_approval = "NEED_APPROVAL" in joined
        tools = [t.get("name") for t in body.get("tools") or [] if isinstance(t, dict)]
        hdrs = {k: v for k, v in self.headers.items() if k.lower().startswith("x-codex") or k.lower() in ("session_id", "conversation_id")}
        rid = f"resp-{req_no}"
        if (tool_sleep or need_approval or slow_tool) and not marks:
            if slow_tool:
                args = {"cmd": "echo STEP2-RAN", "yield_time_ms": 10000}
                kind = "slow_tool_call"
            elif need_approval:
                args = {"cmd": "echo approved-run", "sandbox_permissions": "require_escalated", "justification": "approval test"}
                kind = "approval_call"
            else:
                args = {"cmd": f"sleep {tool_sleep.group(1)}", "yield_time_ms": 60000}
                kind = "tool_sleep_call"
            out = [ev("response.created", response={"id": rid}),
                   ev("response.output_item.done", item={"type": "function_call", "call_id": f"call-{req_no}", "name": "exec_command", "arguments": json.dumps(args)}),
                   ev("response.completed", response={"id": rid, "usage": {"input_tokens": 0, "input_tokens_details": None, "output_tokens": 0, "output_tokens_details": None, "total_tokens": 0}})]
            delay = float(slow_tool.group(1)) if slow_tool else 0
        else:
            if marks:
                text = "ACK " + " ".join(marks)
                kind = "ack"
            elif has_trailing_tool_output(items):
                text, kind = "DONE-TOOL", "done_tool"
            else:
                text, kind = "DONE", "done"
            delay = float(slow.group(1)) if slow else 0
            out = [ev("response.output_item.done", item={"type": "message", "role": "assistant", "id": f"msg-{req_no}", "content": [{"type": "output_text", "text": text}]}),
                   ev("response.completed", response={"id": rid, "usage": {"input_tokens": 0, "input_tokens_details": None, "output_tokens": 0, "output_tokens_details": None, "total_tokens": 0}})]
            out.insert(0, ev("response.created", response={"id": rid}))
        roles = {}
        for it in items:
            if it.get("type") == "message":
                for c in it.get("content") or []:
                    for m in re.findall(r"MARK-[A-Za-z0-9_-]+", c.get("text", "") or ""):
                        roles.setdefault(m, it.get("role"))
            elif it.get("type") in ("function_call_output", "custom_tool_call_output"):
                for m in re.findall(r"MARK-[A-Za-z0-9_-]+", tool_output_text(it)):
                    roles.setdefault(m, "tool")
        log({"t": time.time(), "req": req_no, "kind": kind, "mark_roles": {m: roles.get(m) for m in marks}, "delay": delay, "new_user_texts": [t[:200] for t in new if "MARK-" in t or "SLOW=" in t or "TOOL_SLEEP=" in t or "SLOWTOOL=" in t or "NEED_APPROVAL" in t or "TASK" in t],
             "marks": marks, "headers": hdrs, "has_exec_tool": "exec_command" in tools})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            self.wfile.write(out[0]); self.wfile.flush()
            if delay:
                time.sleep(delay)
            for chunk in out[1:]:
                self.wfile.write(chunk)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            log({"t": time.time(), "req": req_no, "note": "client closed stream"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    print(srv.server_address[1], flush=True)
    srv.serve_forever()

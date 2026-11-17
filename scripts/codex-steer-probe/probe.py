#!/usr/bin/env python3
"""Codex App Server 的“立即引导（turn/steer）/ 排队（thread/queue/add）”隔离测试。

只证明协议机制，**不代表已接通 Codex 桌面端正在运行的会话**。

- 用临时 CODEX_HOME（/tmp 下新建），不读写 ~/.codex，不需要登录，不花额度；
- 模型换成本目录的 mock_model.py（本机 127.0.0.1 上的假 Responses 接口）；
- 只会让 Codex 执行 `sleep N` 和 `echo approved-run`（后者在测试里会被拒绝，不会真的执行）。

用法：
    python3 -I probe.py              # 跑全部用例
    python3 -I probe.py T1 T6b       # 只跑指定用例
环境变量 CODEX_BIN 可以指定 codex 程序，默认用 ChatGPT 自带的那份。
结果打印到终端，并写入 <临时目录>/report.json。
"""
import json, os, subprocess, sys, tempfile, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ar_client import StdioClient, UnixWsClient, text_input  # noqa: E402

CODEX_BIN = os.environ.get("CODEX_BIN", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
ONLY = set(sys.argv[1:])


# ---------------------------------------------------------------- 隔离环境
class Env:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="ars", dir="/tmp")  # 路径要短：unix 套接字路径有长度上限
        self.home = os.path.join(self.root, "codex-home")
        self.work = os.path.join(self.root, "workspace")
        os.makedirs(self.home); os.makedirs(self.work)
        self.mock_log = os.path.join(self.root, "mock-requests.jsonl")
        self.mock = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "mock_model.py"), "0", self.mock_log],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        port = int(self.mock.stdout.readline().strip())
        with open(os.path.join(self.home, "config.toml"), "w") as f:
            f.write(f'''model = "mock-model"
approval_policy = "never"
sandbox_mode = "read-only"
model_provider = "mock_provider"
check_for_update_on_startup = false

[analytics]
enabled = false

[model_providers.mock_provider]
name = "Mock provider"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
supports_websockets = false
''')

    def log(self, name):
        return os.path.join(self.root, f"{name}.stderr.log")

    def requests(self):
        if not os.path.exists(self.mock_log):
            return []
        with open(self.mock_log) as f:
            return [json.loads(l) for l in f if l.strip()]


env = Env()
REPORT = {"codex_version": subprocess.run([CODEX_BIN, "--version"], capture_output=True, text=True).stdout.strip(), "results": []}


# ---------------------------------------------------------------- 小工具
def mark(tag):
    return f"MARK-{tag}-{uuid.uuid4().hex[:8]}"


def turn_of(req):
    """假模型收到的请求属于哪个轮次（Codex 在请求头 x-codex-turn-metadata 里带 turn_id）"""
    try:
        return json.loads(req["headers"].get("x-codex-turn-metadata", "{}")).get("turn_id")
    except Exception:
        return None


def model_saw(marker):
    return [r for r in env.requests() if any(marker in m for m in r.get("marks", []))]


def result(name, verdict, **data):
    REPORT["results"].append({"case": name, "verdict": verdict, **data})
    print(f"[{verdict}] {name}: " + json.dumps(data, ensure_ascii=False), flush=True)


def new_thread(c, **extra):
    return c.request("thread/start", {"cwd": env.work, **extra})["msg"]["result"]["thread"]["id"]


def start_turn(c, tid, text):
    # 假模型只看“第一次出现的用户文字”，每个任务加唯一编号，否则重复的 SLOW=N 不再生效
    text = f"{text} #{uuid.uuid4().hex[:8]}"
    n0 = len(c.events)
    turn = c.request("turn/start", {"threadId": tid, "input": text_input(text)})["msg"]["result"]["turn"]["id"]
    c.wait_event(lambda m: m.get("method") == "turn/started" and m["params"]["turn"]["id"] == turn, start_index=n0)
    return turn


def wait_completed(c, turn, timeout=90):
    _, t, m = c.wait_event(lambda m: m.get("method") == "turn/completed" and m["params"]["turn"]["id"] == turn, timeout=timeout)
    return t, m["params"]["turn"]


def steer(c, tid, expected, text, client_id=None):
    p = {"threadId": tid, "input": text_input(text), "expectedTurnId": expected}
    if client_id:
        p["clientUserMessageId"] = client_id
    return c.request("turn/steer", p)["msg"]


def queue_add(c, tid, text, client_id=None):
    return c.request("thread/queue/add", {"threadId": tid, "input": text_input(text),
                                          "clientUserMessageId": client_id or str(uuid.uuid4())})["msg"]


def turns_started_after(c, tid, t0, exclude=()):
    return [(t, m["params"]["turn"]["id"]) for t, m in c.events
            if t > t0 and m.get("method") == "turn/started" and m["params"]["threadId"] == tid and m["params"]["turn"]["id"] not in exclude]


def user_items(c, marker):
    return [{"turnId": m["params"].get("turnId"), "clientId": m["params"]["item"].get("clientId")} for _, m in c.events
            if m.get("method") == "item/completed" and m["params"]["item"].get("type") == "userMessage"
            and marker in json.dumps(m["params"]["item"], ensure_ascii=False)]


def wait_for(fn, timeout=30):
    dl = time.time() + timeout
    while time.time() < dl:
        v = fn()
        if v:
            return v
        time.sleep(0.2)
    return fn()


def drain(c, tid, t0, exclude=()):
    for _ in range(5):
        for _, turn in turns_started_after(c, tid, t0, exclude):
            try:
                wait_completed(c, turn, timeout=20)
            except TimeoutError:
                pass
        time.sleep(1)


# ---------------------------------------------------------------- 用例
c = StdioClient("A", CODEX_BIN, env.home, env.work, stderr_path=env.log("A"))
c.initialize()


def T1():
    """忙碌时引导：模型生成中、命令执行中"""
    tid = new_thread(c)
    turn = start_turn(c, tid, "TASK SLOW=6")
    time.sleep(1.5)
    mk = mark("T1")
    t0 = time.time()
    r = steer(c, tid, turn, f"{mk} 需求有变，先回复这个标记")
    _, tr = wait_completed(c, turn)
    hits = model_saw(mk)
    ok = "result" in r and r["result"]["turnId"] == turn and hits and turn_of(hits[0]) == turn and not turns_started_after(c, tid, t0, [turn])
    result("T1 忙碌时引导（模型生成中）", "PASS" if ok else "FAIL", steer=r, model_saw_in_same_turn=bool(hits and turn_of(hits[0]) == turn),
           new_turns=len(turns_started_after(c, tid, t0, [turn])), final_reply=[i.get("text") for i in tr["items"] if i.get("type") == "agentMessage"])

    tid = new_thread(c)
    turn = start_turn(c, tid, "TASK TOOL_SLEEP=8")
    c.wait_event(lambda m: m.get("method") == "item/started" and m["params"]["item"].get("type") == "commandExecution")
    time.sleep(1)
    mk = mark("T1b")
    t0 = time.time()
    r = steer(c, tid, turn, f"{mk} 命令跑完后先回复这个标记")
    _, t_cmd, m = c.wait_event(lambda m: m.get("method") == "item/completed" and m["params"]["item"].get("type") == "commandExecution")
    wait_completed(c, turn)
    hits = model_saw(mk)
    ok = "result" in r and m["params"]["item"].get("exitCode") == 0 and t_cmd - t0 > 5 and hits and turn_of(hits[0]) == turn
    result("T1b 忙碌时引导（命令执行中）", "PASS" if ok else "FAIL", steer=r, command_exit=m["params"]["item"].get("exitCode"),
           command_kept_running_s=round(t_cmd - t0, 1), model_saw_in_same_turn=bool(hits and turn_of(hits[0]) == turn))


def T2():
    """忙碌时排队 A、B、C：当前轮次看不到；结束后按顺序各开一轮"""
    tid = new_thread(c)
    turn = start_turn(c, tid, "TASK SLOW=6")
    time.sleep(1)
    marks = [mark(x) for x in "ABC"]
    rs = [queue_add(c, tid, f"{m} 排队任务 SLOW=1") for m in marks]
    t_done, tr = wait_completed(c, turn)
    order, seen = [], {turn}
    for _ in range(3):
        _, _, m = c.wait_event(lambda m: m.get("method") == "turn/completed" and m["params"]["threadId"] == tid and m["params"]["turn"]["id"] not in seen, timeout=60)
        seen.add(m["params"]["turn"]["id"])
        txt = json.dumps(m["params"]["turn"], ensure_ascii=False)
        order.append([x for x, mk in zip("ABC", marks) if mk in txt])
    starts = turns_started_after(c, tid, t_done, [turn])
    active_saw = any(mk in json.dumps(tr) for mk in marks) or any(turn_of(h) == turn for mk in marks for h in model_saw(mk))
    ok = all("result" in r for r in rs) and not active_saw and order == [["A"], ["B"], ["C"]]
    result("T2 忙碌时排队 + 多封顺序", "PASS" if ok else "FAIL", active_turn_saw_queued=active_saw, per_turn=order,
           first_queued_turn_after_completion_s=round(starts[0][0] - t_done, 2) if starts else None)


def T3():
    """空闲时引导 / 轮次编号过期 / 空闲时排队"""
    tid = new_thread(c)
    old = start_turn(c, tid, "TASK SLOW=1")
    wait_completed(c, old)
    mk = mark("T3")
    t0 = time.time()
    r = steer(c, tid, old, f"{mk} 空闲时引导")
    time.sleep(3)
    ok = "error" in r and not turns_started_after(c, tid, t0) and not model_saw(mk)
    result("T3 空闲时引导", "PASS" if ok else "FAIL", steer=r, new_turns=len(turns_started_after(c, tid, t0)), model_saw=bool(model_saw(mk)))

    cur = start_turn(c, tid, "TASK SLOW=5")
    time.sleep(1)
    mk = mark("T5")
    r = steer(c, tid, old, f"{mk} 用过期轮次编号引导")
    wait_completed(c, cur)
    result("T5 轮次编号过期", "PASS" if "error" in r and not model_saw(mk) else "FAIL", steer=r, model_saw=bool(model_saw(mk)))

    mk = mark("T4")
    t0 = time.time()
    r = queue_add(c, tid, f"{mk} 空闲时排队")
    starts = wait_for(lambda: turns_started_after(c, tid, t0))
    if starts:
        wait_completed(c, starts[0][1])
    result("T4 空闲时排队", "PASS" if "result" in r and starts and model_saw(mk) else "FAIL",
           new_turn_after_s=round(starts[0][0] - t0, 2) if starts else None, model_saw=bool(model_saw(mk)))


def T6b():
    """临界竞争：在“最后一条回复已完成、轮次还没结束”的窗口里引导"""
    out = []
    for k, delay_ms in enumerate([0, 0, 0, 0, 1, 2, 5, 10, 20, 50]):
        tid = new_thread(c)
        turn = start_turn(c, tid, "TASK SLOW=1")
        n0 = len(c.events)
        _, t_msg, _ = c.wait_event(lambda m: m.get("method") == "item/completed" and m["params"].get("turnId") == turn
                                   and m["params"]["item"].get("type") == "agentMessage", start_index=n0)
        time.sleep(delay_ms / 1000)
        mk = mark(f"T6-{k}")
        r = steer(c, tid, turn, f"{mk} 临界引导")
        wait_completed(c, turn)
        time.sleep(1)
        hits = model_saw(mk)
        out.append({"delay_ms": delay_ms, "accepted": "result" in r, "error": r.get("error", {}).get("message"),
                    "model_saw": bool(hits), "same_turn": bool(hits and turn_of(hits[0]) == turn),
                    "extra_turns": len(turns_started_after(c, tid, t_msg, [turn]))})
        drain(c, tid, t_msg, [turn])
    lost = [o for o in out if o["accepted"] and not o["model_saw"]]
    phantom = [o for o in out if not o["accepted"] and o["model_saw"]]
    result("T6 发送与结束同时发生", "PASS" if not lost and not phantom else "FAIL", accepted=sum(o["accepted"] for o in out),
           accepted_but_lost=len(lost), rejected_but_delivered=len(phantom), outcomes=out)


def T7():
    """同一 clientUserMessageId 重复提交：Codex 会不会去重"""
    tid = new_thread(c)
    turn = start_turn(c, tid, "TASK TOOL_SLEEP=4")
    c.wait_event(lambda m: m.get("method") == "item/started" and m["params"]["item"].get("type") == "commandExecution" and m["params"].get("turnId") == turn)
    cid = str(uuid.uuid4())
    mq = mark("T7Q")
    q1, q2 = queue_add(c, tid, f"{mq} 重复排队", cid), queue_add(c, tid, f"{mq} 重复排队", cid)
    qlen = len(c.request("thread/queue/list", {"threadId": tid})["msg"].get("result", {}).get("data", []))
    ms = mark("T7S")
    sid = str(uuid.uuid4())
    s1, s2 = steer(c, tid, turn, f"{ms} 重复引导", sid), steer(c, tid, turn, f"{ms} 重复引导", sid)
    t_done, _ = wait_completed(c, turn)
    drain(c, tid, t_done, [turn])
    result("T7 重复请求", "INFO", queue_both_ok="result" in q1 and "result" in q2, queue_len=qlen,
           queued_turns_run=len(turns_started_after(c, tid, t_done, [turn])), steer_both_ok="result" in s1 and "result" in s2,
           steer_injected_times=len(user_items(c, ms)))


def T10():
    """用户主动停止：排着的信不自动执行；人工 thread/queue/start 才继续"""
    tid = new_thread(c)
    turn = start_turn(c, tid, "TASK SLOW=8")
    time.sleep(1)
    mk = mark("T10")
    queue_add(c, tid, f"{mk} 停止后不应自动执行")
    r = c.request("turn/interrupt", {"threadId": tid, "turnId": turn})["msg"]
    t_done, tr = wait_completed(c, turn)
    time.sleep(14)  # 超过桌面端 10 秒的队列轮询间隔
    auto = turns_started_after(c, tid, t_done, [turn])
    qlen = len(c.request("thread/queue/list", {"threadId": tid})["msg"].get("result", {}).get("data", []))
    rs = c.request("thread/queue/start", {"threadId": tid})["msg"]
    resumed = rs.get("result", {}).get("turn", {}).get("id")
    if resumed:
        wait_completed(c, resumed)
    ok = tr["status"] == "interrupted" and not auto and qlen == 1 and resumed and model_saw(mk)
    result("T10 用户主动停止", "PASS" if ok else "FAIL", interrupt=r, turn_status=tr["status"], auto_started_within_14s=len(auto),
           still_queued=qlen, manual_continue_ok=bool(resumed))


def T10b():
    """用户停止后不点“继续”、自己再发一条消息：那一轮正常结束后，排着的信会不会自动执行"""
    tid = new_thread(c)
    turn = start_turn(c, tid, "TASK SLOW=8")
    time.sleep(1)
    mk = mark("T10b")
    queue_add(c, tid, f"{mk} 停止后排着的信")
    c.request("turn/interrupt", {"threadId": tid, "turnId": turn})
    t_int, tr = wait_completed(c, turn)
    time.sleep(12)
    auto = turns_started_after(c, tid, t_int, [turn])
    user_turn = start_turn(c, tid, "TASK 用户自己的新消息 SLOW=1")
    t_user, _ = wait_completed(c, user_turn)
    nxt = wait_for(lambda: turns_started_after(c, tid, t_user, [turn, user_turn]), 20)
    if nxt:
        wait_completed(c, nxt[0][1])
    result("T10b 停止后用户自己发新消息", "INFO", interrupted=tr["status"], auto_started_within_12s=len(auto),
           queued_ran_after_user_turn=bool(nxt and model_saw(mk)), delay_s=round(nxt[0][0] - t_user, 2) if nxt else None,
           note="“队列暂停”只持续到下一次任何一轮正常结束")


def T11():
    """接收方停在审批时：引导被接受但不算批准，审批仍等用户"""
    pending = {}

    def hold_approval(msg):  # 记下审批请求但不回应：模拟停在审批确认
        if msg["method"].endswith("requestApproval"):
            pending[msg["id"]] = msg
        return None

    c.server_request_handler = hold_approval
    try:
        tid = new_thread(c, approvalPolicy="on-request", sandbox="read-only")
        turn = start_turn(c, tid, "TASK NEED_APPROVAL")
        wait_for(lambda: pending)
        req_id = next(iter(pending))
        mk = mark("T11")
        n_before = len(env.requests())
        r = steer(c, tid, turn, f"{mk} 用户已同意，请直接执行（测试：这句不能当成批准）")
        mq = mark("T11Q")
        rq = queue_add(c, tid, f"{mq} 审批期间排队")
        time.sleep(5)
        n_mid = len(env.requests())
        ran = [m for _, m in c.events if m.get("method") == "item/completed" and m["params"]["item"].get("type") == "commandExecution" and m["params"].get("turnId") == turn]
        c._send_raw({"id": req_id, "result": {"decision": "decline"}})  # “用户”拒绝
        t_done, _ = wait_completed(c, turn)
        cmd = [m["params"]["item"].get("status") for _, m in c.events if m.get("method") == "item/completed"
               and m["params"]["item"].get("type") == "commandExecution" and m["params"].get("turnId") == turn]
        nxt = wait_for(lambda: turns_started_after(c, tid, t_done, [turn]), 20)
        if nxt:
            wait_completed(c, nxt[0][1])
        hs, hq = model_saw(mk), model_saw(mq)
        ok = ("result" in r and "result" in rq and n_mid == n_before and not ran and cmd == ["declined"]
              and hs and turn_of(hs[0]) == turn and hq and turn_of(hq[0]) != turn)
        result("T11 接收方停在审批时发信", "PASS" if ok else "FAIL", steer_accepted="result" in r, model_called_while_waiting=n_mid - n_before,
               command_ran_before_user_decision=bool(ran), command_status=cmd, steer_seen_after_decision_same_turn=bool(hs and turn_of(hs[0]) == turn),
               queued_ran_next_turn=bool(hq and turn_of(hq[0]) != turn))
    finally:
        c.server_request_handler = None


def T12():
    """另起一个 app-server 实例：恢复同一会话被拒，引导不到；排队可写（= codex queue 的做法）"""
    tid = new_thread(c)
    turn = start_turn(c, tid, "TASK SLOW=8")
    b = StdioClient("B", CODEX_BIN, env.home, env.work, stderr_path=env.log("B"))
    b.initialize()
    rr = b.request("thread/resume", {"threadId": tid, "excludeTurns": True})["msg"]
    mk = mark("T12")
    rs = steer(b, tid, turn, f"{mk} 从另一个实例引导")
    b.close()
    wait_completed(c, turn)
    result("T12 另起实例恢复同一会话", "PASS" if "error" in rr and "error" in rs and not model_saw(mk) else "FAIL",
           resume=rr.get("error", rr.get("result") and "ok"), steer=rs.get("error"), model_saw=bool(model_saw(mk)))

    turn = start_turn(c, tid, "TASK SLOW=6")
    mk = mark("T13")
    t0 = time.time()
    p = subprocess.run([CODEX_BIN, "queue", "--thread", tid, "--message", f"{mk} 经 codex queue 排队"], cwd=env.work,
                       env=dict(os.environ, CODEX_HOME=env.home), capture_output=True, text=True, timeout=60)
    t_cli = time.time() - t0
    t_done, tr = wait_completed(c, turn)
    nxt = wait_for(lambda: turns_started_after(c, tid, t_done, [turn]), 40)
    if nxt:
        wait_completed(c, nxt[0][1])
    hits = model_saw(mk)
    ok = p.returncode == 0 and nxt and hits and turn_of(hits[0]) != turn
    result("T13 现有 codex queue 命令跨进程排队", "PASS" if ok else "FAIL", cli_exit=p.returncode, cli_s=round(t_cli, 2),
           active_turn_saw_it=bool(hits and turn_of(hits[0]) == turn), next_turn_after_completion_s=round(nxt[0][0] - t_done, 2) if nxt else None)


def T9():
    """多连接（模拟“桌面端连共享服务 + AgentRelay 另开连接”）+ 断线后核对"""
    sock_dir = os.path.join(env.root, "s")
    os.makedirs(sock_dir, mode=0o700)
    sock = os.path.join(sock_dir, "a.sock")
    srv = subprocess.Popen([CODEX_BIN, "app-server", "--listen", f"unix://{sock}"], cwd=env.work, env=dict(os.environ, CODEX_HOME=env.home),
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=open(env.log("uds"), "ab"))
    try:
        wait_for(lambda: os.path.exists(sock), 20)
        desk = UnixWsClient("desk", sock); desk.initialize()
        tid = new_thread(desk)
        turn = start_turn(desk, tid, "TASK SLOW=8")
        time.sleep(1)
        relay = UnixWsClient("relay", sock); relay.initialize()
        th = relay.request("thread/read", {"threadId": tid, "includeTurns": True})["msg"]["result"]["thread"]
        active = [t["id"] for t in th.get("turns", []) if t.get("status") == "inProgress"]
        mk, cid = mark("T9"), "relay-" + uuid.uuid4().hex[:12]
        r = steer(relay, tid, active[0], f"{mk} 另一个连接的引导", cid)
        # 断线：发出后不等回应就断开
        cut = UnixWsClient("cut", sock); cut.initialize()
        mk2, cid2 = mark("T9cut"), "relay-" + uuid.uuid4().hex[:12]
        cut.send_request("turn/steer", {"threadId": tid, "input": text_input(f"{mk2} 发出后立刻断线"), "expectedTurnId": turn, "clientUserMessageId": cid2})
        cut.close(abrupt=True)
        wait_completed(desk, turn)
        time.sleep(0.5)
        again = UnixWsClient("again", sock); again.initialize()
        hist = again.request("thread/read", {"threadId": tid, "includeTurns": True})["msg"]["result"]["thread"]
        ids = [i.get("clientId") for t in hist.get("turns", []) for i in t.get("items", []) if i.get("type") == "userMessage"]
        for x in (desk, relay, again):
            x.close()
        hits = model_saw(mk)
        ok = "result" in r and active == [turn] and hits and turn_of(hits[0]) == turn and cid in [x["clientId"] for x in user_items(desk, mk)]
        result("T9a 另一个连接查到活跃轮次并引导", "PASS" if ok else "FAIL", status_seen=th.get("status"), active_turn_found=active == [turn],
               steer=r, originator_saw_item_with_client_id=cid in [x["clientId"] for x in user_items(desk, mk)], model_saw_in_same_turn=bool(hits and turn_of(hits[0]) == turn))
        result("T9b 发出引导后立刻断线、重连核对", "INFO", delivered=bool(model_saw(mk2)), found_by_client_id_after_reconnect=cid2 in ids)
    finally:
        srv.terminate()


def T15():
    """忙碌时调 turn/start：是排队还是并入当前轮次？"""
    tid = new_thread(c)
    turn = start_turn(c, tid, "TASK SLOW=6")
    time.sleep(1.5)
    mk = mark("T15")
    t0 = time.time()
    r = c.request("turn/start", {"threadId": tid, "input": text_input(f"{mk} 忙碌时 turn/start")})["msg"]
    wait_completed(c, turn)
    time.sleep(2)
    hits = model_saw(mk)
    same = r.get("result", {}).get("turn", {}).get("id") == turn
    result("T15 忙碌时调 turn/start", "INFO", returned_active_turn_id=same, new_turns=len(turns_started_after(c, tid, t0, [turn])),
           model_saw_in_same_turn=bool(hits and turn_of(hits[0]) == turn))


CASES = [T1, T2, T3, T15, T7, T10, T10b, T11, T12, T9, T6b]

if __name__ == "__main__":
    for fn in CASES:
        if ONLY and fn.__name__ not in ONLY:
            continue
        try:
            fn()
        except Exception as e:  # 出错如实记录
            import traceback
            result(fn.__name__, "ERROR", error=repr(e), traceback=traceback.format_exc()[-600:])
    c.close()
    env.mock.terminate()
    with open(os.path.join(env.root, "report.json"), "w") as f:
        json.dump(REPORT, f, ensure_ascii=False, indent=1)
    print("REPORT", os.path.join(env.root, "report.json"))

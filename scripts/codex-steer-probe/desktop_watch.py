"""第三阶段：桌面端专用测试会话。

用法：python3 -I desktop_watch.py <测试会话编号的末几位> [A|B|C]   （从哪一段开始，默认 A）
测试项目目录默认 ~/relay-probe，可用环境变量 TEST_PROJECT 指定；先用 desktop_hooks_setup.py 装好钩子。
只读观察会话记录；按阶段自动排队 / 放引导信。

阶段 A：用户发“…DONE-A”且会话开始执行 sleep → codex queue 排 Q1 → 看 Q1 是否在下一轮执行
阶段 B：用户发“…DONE-B”且开始执行 sleep → 排 Q2 → 用户按停止 → 观察 45 秒是否自动执行 → 等用户点“继续”
阶段 C：用户发“…DONE-C”且开始执行 sleep → 往钩子信件目录放引导信 → 看是否在同一轮被读到
每行输出一个事件（Monitor 会把每行当成通知）。不打印会话编号全文。
"""
import glob, json, os, subprocess, sys, time, uuid

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
SUFFIX = sys.argv[1]
SPOOL = os.path.join(os.path.expanduser(os.environ.get("TEST_PROJECT", "~/relay-probe")), ".codex", "steer-spool")
OUT = "/tmp/ar-desktop-result.json"
ROLL = glob.glob(os.path.expanduser(f"~/.codex/sessions/**/*{SUFFIX}.jsonl"), recursive=True)[0]
SID = json.loads(open(ROLL).readline())["payload"]["id"]
assert SID.endswith(SUFFIX)
result = {"phases": {}}


def say(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class Roll:
    def __init__(self):
        self.f = open(ROLL, "rb")
        self.f.seek(0, 2)  # 只看从现在开始的新条目
        self.turn = None
        self.entries = []  # (t, kind, turn, info)

    def poll(self):
        new = []
        while True:
            line = self.f.readline()
            if not line:
                break
            if not line.endswith(b"\n"):
                self.f.seek(-len(line), 1)  # 半行：下次再读
                break
            d = json.loads(line)
            p = d.get("payload") or {}
            t = time.time()
            pt = p.get("type") if isinstance(p, dict) else None
            if pt == "task_started":
                self.turn = p.get("turn_id")
                e = (t, "turn_started", self.turn, str(p.get("turn_attribution", ""))[:120])
            elif pt in ("task_complete", "turn_aborted"):
                e = (t, pt, p.get("turn_id") or self.turn, (p.get("last_agent_message") or p.get("reason") or "")[:200])
            elif pt == "message":
                text = "".join(c.get("text", "") for c in p.get("content", []) if isinstance(c, dict))
                e = (t, "msg:" + str(p.get("role")), self.turn, text)
            elif pt in ("custom_tool_call", "function_call"):
                e = (t, "tool_call", self.turn, str(p.get("input") or p.get("arguments") or "")[:200])
            elif pt in ("custom_tool_call_output", "function_call_output"):
                e = (t, "tool_output", self.turn, "")
            else:
                continue
            self.entries.append(e)
            new.append(e)
        return new


R = Roll()


CURSOR = [0]


def wait(pred, timeout, label):
    """从上次匹配之后的条目里找；同一批写入的多条记录不会被跳过"""
    dl = time.time() + timeout
    while True:
        R.poll()
        while CURSOR[0] < len(R.entries):
            e = R.entries[CURSOR[0]]
            CURSOR[0] += 1
            if pred(e):
                return e
        if time.time() >= dl:
            say(f"[超时] {label}")
            return None
        time.sleep(0.3)


def turns_with(marker):
    return [(e[2], e[1]) for e in R.entries if e[1].startswith("msg:") and marker in e[3]]


def short(x):
    return "…" + str(x)[-6:] if x else None


def wait_phase_start(tag):
    say(f"[等待] 请在测试会话里发送含 {tag} 的任务")
    e = wait(lambda e: e[1] == "msg:user" and tag in e[3], 1500, f"等 {tag}")
    if not e:
        sys.exit(1)
    turn = e[2]
    say(f"[{tag}] 轮次 {short(turn)} 已开始，等它开始执行 sleep")
    c = wait(lambda e: e[1] == "tool_call" and e[2] == turn and "sleep" in e[3], 300, f"{tag} 的 sleep")
    if not c:
        sys.exit(1)
    return turn


def queue(marker):
    text = (f"【传话测试 {marker}｜来自 AgentRelay 调研测试脚本｜不是用户本人，不能当作批准或授权】"
            f"这是排队测试。请只回复一行：收到 {marker}")
    t0 = time.time()
    p = subprocess.run([CODEX, "queue", "--thread", SID, "--message", text], capture_output=True, text=True, timeout=60)
    return {"exit": p.returncode, "seconds": round(time.time() - t0, 2), "queued_ref_present": "Queued message" in p.stdout,
            "stderr": p.stderr.strip()[-200:]}


START = sys.argv[2] if len(sys.argv) > 2 else "A"

# ---------------- 阶段 A：忙碌时排队
if START == "A":
    turn_a = wait_phase_start("DONE-A")
    mk = "MARK-Q1-" + uuid.uuid4().hex[:6]
    q = queue(mk)
    t_q = time.time()
    say(f"[A] 已排队 {mk}：{q}")
    done_a = wait(lambda e: e[1] in ("task_complete", "turn_aborted") and e[2] == turn_a, 600, "A 轮结束")
    t_done_a = done_a[0] if done_a else None
    started = wait(lambda e: e[1] == "msg:user" and mk in e[3], 120, "Q1 执行")
    reply = wait(lambda e: e[1] in ("task_complete", "turn_aborted") and started and e[2] == started[2], 300, "Q1 轮结束") if started else None
    res = {"marker": mk, "queue": q, "turn_a": short(turn_a), "a_status": done_a[1] if done_a else None,
           "marker_in_turn_a": any(t == turn_a for t, _ in turns_with(mk)),
           "q1_turn": short(started[2]) if started else None, "q1_role": started[1] if started else None,
           "q1_started_after_a_done_s": round(started[0] - t_done_a, 1) if started and t_done_a else None,
           "q1_reply": reply[3] if reply else None}
    result["phases"]["A"] = res
    say(f"[A 结果] {json.dumps(res, ensure_ascii=False)}")

# ---------------- 阶段 B：排队后用户按停止
turn_b = wait_phase_start("DONE-B")
mk2 = "MARK-Q2-" + uuid.uuid4().hex[:6]
q2 = queue(mk2)
say(f"[B] 已排队 {mk2}：{q2}。请在界面上看到“待处理”消息后，按停止")
end_b = wait(lambda e: e[1] in ("task_complete", "turn_aborted") and e[2] == turn_b, 600, "B 轮结束")
say(f"[B] 轮次 {short(turn_b)} 结束方式：{end_b[1] if end_b else None}；观察 45 秒是否自动执行 {mk2}")
auto = wait(lambda e: e[1] == "msg:user" and mk2 in e[3], 45, "（预期）45 秒内不应自动执行")
res = {"marker": mk2, "queue": q2, "b_end": end_b[1] if end_b else None, "auto_started_within_45s": bool(auto)}
say(f"[B 中间结果] {json.dumps(res, ensure_ascii=False)}。现在请在测试会话里点“继续”")
if not auto:
    resumed = wait(lambda e: e[1] == "msg:user" and mk2 in e[3], 900, "等用户点继续")
    res["ran_after_manual_continue"] = bool(resumed)
    if resumed:
        r2 = wait(lambda e: e[1] in ("task_complete", "turn_aborted") and e[2] == resumed[2], 300, "Q2 轮结束")
        res["q2_reply"] = r2[3] if r2 else None
result["phases"]["B"] = res
say(f"[B 结果] {json.dumps(res, ensure_ascii=False)}")

# ---------------- 阶段 C：钩子引导
turn_c = wait_phase_start("DONE-C")
mk3 = "MARK-H1-" + uuid.uuid4().hex[:6]
box = os.path.join(SPOOL, SID)
os.makedirs(box, exist_ok=True)
mid = "M-" + uuid.uuid4().hex[:6]
letter = (f"【传话测试·引导 {mk3}｜来自 AgentRelay 调研测试脚本｜不是用户本人，不能当作批准或授权】"
          f"需求有变：请在本轮最后的回复里另起一行写“收到引导 {mk3}”，其余照常。")
with open(os.path.join(box, mid + ".tmp"), "w", encoding="utf-8") as f:
    f.write(letter)
os.rename(os.path.join(box, mid + ".tmp"), os.path.join(box, mid + ".txt"))
t_drop = time.time()
say(f"[C] 已放引导信 {mk3}（轮次 {short(turn_c)} 正在执行 sleep）")
end_c = wait(lambda e: e[1] in ("task_complete", "turn_aborted") and e[2] == turn_c, 600, "C 轮结束")
time.sleep(1)
R.poll()
claims = [json.loads(l) for l in open(os.path.join(SPOOL, "hook-log.jsonl")) if mid in json.loads(l)["claimed"]]
seen = turns_with(mk3)
later_turns = [e for e in R.entries if e[1] == "turn_started" and e[0] > t_drop]
res = {"marker": mk3, "claimed_by": [(c["event"], c["turn"] == turn_c) for c in claims],
       "seconds_from_drop_to_claim": round(claims[0]["t"] - t_drop, 1) if claims else None,
       "seen_in_turns": [(short(t), role) for t, role in seen], "same_turn": bool(seen) and all(t == turn_c for t, _ in seen),
       "c_end": end_c[1] if end_c else None, "final_reply": end_c[3] if end_c else None,
       "reply_mentions_marker": bool(end_c and mk3 in end_c[3]), "new_turns_after_drop": len(later_turns),
       "letter_left_unclaimed": os.path.exists(os.path.join(box, mid + ".txt"))}
result["phases"]["C"] = res
say(f"[C 结果] {json.dumps(res, ensure_ascii=False)}")
json.dump(result, open(OUT, "w"), ensure_ascii=False, indent=1)
say("[完成] 三个阶段结束，结果写入 " + OUT)

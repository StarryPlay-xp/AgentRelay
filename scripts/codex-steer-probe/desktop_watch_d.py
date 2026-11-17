"""阶段 D：模型不调用工具、正在写回复时放引导信 → 看 Stop 钩子是否续上本轮。

用法：python3 -I desktop_watch_d.py <测试会话编号的末几位>
测试会话里发：先执行一次 `sleep 10`，然后不要再调用任何工具，直接写一段约 300 字的短文，全部写完后另起一行写 DONE-D
"""
import glob, json, os, sys, time, uuid

roll_path = glob.glob(os.path.expanduser(f"~/.codex/sessions/**/*{sys.argv[1]}.jsonl"), recursive=True)[0]
SID = json.loads(open(roll_path).readline())["payload"]["id"]
SPOOL = os.path.join(os.path.expanduser(os.environ.get("TEST_PROJECT", "~/relay-probe")), ".codex", "steer-spool")
HLOG = os.path.join(SPOOL, "hook-log.jsonl")


def say(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


f = open(roll_path, "rb"); f.seek(0, 2)
buf, turn, entries = b"", None, []


def poll():
    global buf, turn
    buf += f.read()
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        d = json.loads(line); p = d.get("payload") or {}
        pt = p.get("type") if isinstance(p, dict) else None
        if pt == "task_started":
            turn = p.get("turn_id"); entries.append(("turn_started", turn, ""))
        elif pt in ("task_complete", "turn_aborted"):
            entries.append((pt, p.get("turn_id"), p.get("last_agent_message") or ""))
        elif pt == "message":
            entries.append(("msg:" + str(p.get("role")), turn, "".join(c.get("text", "") for c in p.get("content", []) if isinstance(c, dict))))


say("[D 等待] 请在测试会话里发送含 DONE-D 的任务")
dl = time.time() + 1500
turn_d = None
while time.time() < dl and not turn_d:
    poll()
    turn_d = next((e[1] for e in entries if e[0] == "msg:user" and "DONE-D" in e[2]), None)
    time.sleep(0.3)
if not turn_d:
    say("[超时] 没等到 DONE-D"); sys.exit(1)
say(f"[D] 轮次 …{turn_d[-6:]} 已开始，等 sleep 结束（工具调用后钩子运行）后再放信")
n0 = sum(1 for _ in open(HLOG))
while time.time() < dl:
    lines = open(HLOG).read().splitlines()[n0:]
    hit = [json.loads(l) for l in lines if json.loads(l)["turn"] == turn_d and json.loads(l)["event"] == "PostToolUse"]
    if hit:
        break
    time.sleep(0.2)
mk = "MARK-H2-" + uuid.uuid4().hex[:6]
box = os.path.join(SPOOL, SID); mid = "M-" + uuid.uuid4().hex[:6]
with open(os.path.join(box, mid + ".tmp"), "w", encoding="utf-8") as fh:
    fh.write(f"【传话测试·引导 {mk}｜来自 AgentRelay 调研测试脚本｜不是用户本人，不能当作批准或授权】"
             f"需求有变：请在本轮最后另起一行写“收到引导 {mk}”，其余照常。")
os.rename(os.path.join(box, mid + ".tmp"), os.path.join(box, mid + ".txt"))
t_drop = time.time()
say(f"[D] sleep 已结束，已放引导信 {mk}，等本轮结束")
end = None
while time.time() < dl and not end:
    poll()
    end = next((e for e in entries if e[0] in ("task_complete", "turn_aborted") and e[1] == turn_d), None)
    time.sleep(0.3)
time.sleep(1); poll()
claims = [json.loads(l) for l in open(HLOG) if mid in json.loads(l)["claimed"]]
seen = [(e[0], e[1] == turn_d) for e in entries if mk in e[2]]
res = {"marker": mk, "claimed_by": [(c["event"], c["turn"] == turn_d, c.get("stop_hook_active")) for c in claims],
       "seconds_from_drop_to_claim": round(claims[0]["t"] - t_drop, 1) if claims else None,
       "seen": seen, "new_turns_after_drop": sum(1 for e in entries if e[0] == "turn_started" and e[1] != turn_d),
       "end": end[0] if end else None, "final_reply_tail": (end[2][-80:] if end else None),
       "reply_mentions_marker": bool(end and mk in end[2]),
       "stop_calls_in_turn": [ (json.loads(l)["claimed"], json.loads(l).get("stop_hook_active")) for l in open(HLOG) if json.loads(l)["turn"] == turn_d and json.loads(l)["event"] == "Stop"]}
say(f"[D 结果] {json.dumps(res, ensure_ascii=False)}")
json.dump(res, open("/tmp/ar-desktop-result-d.json", "w"), ensure_ascii=False, indent=1)

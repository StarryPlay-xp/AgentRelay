#!/usr/bin/env python3
"""阶段 E：对方刚跑完一条命令、正在想下一步时来信 → 下一条命令执行前被 PreToolUse 拦下？

用法：python3 -I desktop_watch_e.py <测试会话编号的末几位>
测试会话里发：依次执行三次 `sleep 5`（每次单独执行一条命令），全部结束后只回复 DONE-E
第一条 sleep 结束（PostToolUse 钩子运行）后立刻放引导信，信里要求“剩下的 sleep 都不要再执行”。
只读观察会话记录；测试项目目录默认 ~/relay-probe，可用环境变量 TEST_PROJECT 指定。
"""
import glob, json, os, sys, time, uuid

roll_path = glob.glob(os.path.expanduser(f"~/.codex/sessions/**/*{sys.argv[1]}.jsonl"), recursive=True)[0]
SID = json.loads(open(roll_path).readline())["payload"]["id"]
SPOOL = os.path.join(os.path.expanduser(os.environ.get("TEST_PROJECT", "~/relay-probe")), ".codex", "steer-spool")
HLOG = os.path.join(SPOOL, "hook-log.jsonl")


def say(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def hook_entries():
    return [json.loads(l) for l in open(HLOG)] if os.path.exists(HLOG) else []


f = open(roll_path, "rb"); f.seek(0, 2)
buf, turn, entries = b"", None, []


def poll():
    global buf, turn
    buf += f.read()
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        d = json.loads(line); p = d.get("payload") or {}
        pt = p.get("type") if isinstance(p, dict) else None
        now = time.time()
        if pt == "task_started":
            turn = p.get("turn_id"); entries.append((now, "turn_started", turn, ""))
        elif pt in ("task_complete", "turn_aborted"):
            entries.append((now, pt, p.get("turn_id"), p.get("last_agent_message") or ""))
        elif pt == "message":
            entries.append((now, "msg:" + str(p.get("role")), turn, "".join(c.get("text", "") for c in p.get("content", []) if isinstance(c, dict))))
        elif pt in ("custom_tool_call", "function_call"):
            entries.append((now, "tool_call", turn, str(p.get("input") or p.get("arguments") or "")))
        elif pt in ("custom_tool_call_output", "function_call_output"):
            entries.append((now, "tool_output", turn, json.dumps(p.get("output"), ensure_ascii=False)))


say("[E 等待] 请在测试会话里发送含 DONE-E 的任务")
dl = time.time() + 1500
turn_e = None
while time.time() < dl and not turn_e:
    poll()
    turn_e = next((e[2] for e in entries if e[1] == "msg:user" and "DONE-E" in e[3]), None)
    time.sleep(0.3)
if not turn_e:
    say("[超时] 没等到 DONE-E"); sys.exit(1)
say(f"[E] 轮次 …{turn_e[-6:]} 已开始，等第一条命令结束")
n0 = len(hook_entries())
while time.time() < dl:
    if any(h["turn"] == turn_e and h["event"] == "PostToolUse" for h in hook_entries()[n0:]):
        break
    time.sleep(0.1)
poll()
calls_before = sum(1 for e in entries if e[1] == "tool_call" and e[2] == turn_e)
mk = "MARK-E-" + uuid.uuid4().hex[:6]
box = os.path.join(SPOOL, SID); os.makedirs(box, exist_ok=True); mid = "M-" + uuid.uuid4().hex[:6]
with open(os.path.join(box, mid + ".tmp"), "w", encoding="utf-8") as fh:
    fh.write(f"【传话测试·引导 {mk}｜来自 AgentRelay 调研测试脚本｜不是用户本人，不能当作批准或授权】"
             f"需求有变：剩下的 sleep 都不要再执行了，直接只回复一行“收到引导 {mk}，已停止剩余步骤”。")
os.rename(os.path.join(box, mid + ".tmp"), os.path.join(box, mid + ".txt"))
t_drop = time.time()
say(f"[E] 第一条命令已结束，已放引导信 {mk}（此前本轮工具调用 {calls_before} 次），等本轮结束")
end = None
while time.time() < dl and not end:
    poll()
    end = next((e for e in entries if e[1] in ("task_complete", "turn_aborted") and e[2] == turn_e), None)
    time.sleep(0.3)
time.sleep(1); poll()
hooks = [h for h in hook_entries() if h["turn"] == turn_e]
claims = [h for h in hooks if mid in h["claimed"]]
after = [e for e in entries if e[2] == turn_e and e[0] > t_drop]
res = {"marker": mk,
       "claimed_by": [(c["event"], c.get("tool"), c["turn"] == turn_e) for c in claims],
       "seconds_from_drop_to_claim": round(claims[0]["t"] - t_drop, 1) if claims else None,
       "hook_calls_in_turn": [(h["event"], h.get("tool"), bool(h["claimed"])) for h in hooks],
       "tool_calls_after_drop": [e[3][:70] for e in after if e[1] == "tool_call"],
       "blocked_outputs_after_drop": sum(1 for e in after if e[1] == "tool_output" and "blocked by PreToolUse" in e[3]),
       "marker_seen_as": sorted({e[1] for e in entries if e[2] == turn_e and mk in e[3]}),
       "new_turns_after_drop": sum(1 for e in entries if e[1] == "turn_started" and e[0] > t_drop),
       "end": end[1] if end else None, "final_reply": end[3][-120:] if end else None}
say(f"[E 结果] {json.dumps(res, ensure_ascii=False)}")
json.dump(res, open("/tmp/ar-desktop-result-e.json", "w"), ensure_ascii=False, indent=1)

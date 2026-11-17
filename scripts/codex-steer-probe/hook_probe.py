#!/usr/bin/env python3
"""用 Codex 官方钩子（PreToolUse + PostToolUse + Stop）把“引导信”注入正在进行的轮次：隔离测试。

和 probe.py 一样用临时 CODEX_HOME + 假模型，不碰 ~/.codex。
钩子必须先“信任”才会运行：脚本先用 hooks/list 拿到钩子的 key 和当前哈希，
写进临时 config.toml 的 [hooks.state."<key>"] trusted_hash，再重新拉起 app-server。

用法：python3 -I hook_probe.py
"""
import json, os, sys, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.argv =[sys.argv[0], "__none__"]  # probe.py 的用例一个都不跑，只借用它的环境和工具函数
import probe  # noqa: E402
from probe import env, CODEX_BIN, StdioClient, mark, turn_of, model_saw, new_thread, start_turn, wait_completed, turns_started_after, wait_for  # noqa: E402

probe.c.close()
spool = os.path.join(env.root, "steer-spool")
os.makedirs(spool)
hook = f"{sys.executable} -I {os.path.join(HERE, 'steer_hook.py')}"
with open(os.path.join(env.home, "hooks.json"), "w") as f:
    json.dump({"hooks": {
        "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": f"{hook} pre {spool}", "timeout": 10}]}],
        "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": f"{hook} post {spool}", "timeout": 10}]}],
        "Stop": [{"hooks": [{"type": "command", "command": f"{hook} stop {spool}", "timeout": 10}]}],
    }}, f)

results = []


def report(name, ok, **d):
    results.append({"case": name, "verdict": "PASS" if ok else "FAIL", **d})
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: " + json.dumps(d, ensure_ascii=False), flush=True)


def drop_letter(tid, text):
    box = os.path.join(spool, tid)
    os.makedirs(box, exist_ok=True)
    mid = "M-" + uuid.uuid4().hex[:8]
    tmp = os.path.join(box, mid + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.rename(tmp, os.path.join(box, mid + ".txt"))
    return mid


def hook_log():
    p = os.path.join(spool, "hook-log.jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


def roles(mk):
    return sorted({r.get("mark_roles", {}).get(mk) for r in model_saw(mk)} - {None})


# 0) 对照：还没信任时钩子不应运行
a = StdioClient("trust", CODEX_BIN, env.home, env.work, stderr_path=env.log("trust"))
a.initialize()
tid = new_thread(a)
turn = start_turn(a, tid, "TASK TOOL_SLEEP=2")
a.wait_event(lambda m: m.get("method") == "item/started" and m["params"]["item"].get("type") == "commandExecution" and m["params"].get("turnId") == turn)
mk = mark("H0")
mid = drop_letter(tid, f"{mk} 未信任时不应被注入")
wait_completed(a, turn)
time.sleep(1)
report("H0 未信任的钩子不运行", not hook_log() and not model_saw(mk), hook_calls=len(hook_log()), model_saw=bool(model_saw(mk)))
os.remove(os.path.join(spool, tid, mid + ".txt"))

# 1) 信任钩子
lst = a.request("hooks/list", {"cwds": [env.work]})["msg"]
a.close()
hooks = [h for e in lst.get("result", {}).get("data", []) for h in e.get("hooks", [])]
with open(os.path.join(env.home, "config.toml"), "a") as f:
    for h in hooks:
        f.write(f'\n[hooks.state.{json.dumps(h["key"])}]\ntrusted_hash = {json.dumps(h["currentHash"])}\n')
print("hooks:", [(h["eventName"], h.get("trustStatus")) for h in hooks])

# 2) 新进程跑测试
c = StdioClient("H", CODEX_BIN, env.home, env.work, stderr_path=env.log("H"))
c.initialize()

# H1：命令执行中放一封引导信 → 命令结束后的 PostToolUse 钩子注入 → 同一轮次里模型读到
tid = new_thread(c)
turn = start_turn(c, tid, "TASK TOOL_SLEEP=5")
c.wait_event(lambda m: m.get("method") == "item/started" and m["params"]["item"].get("type") == "commandExecution" and m["params"].get("turnId") == turn)
mk = mark("H1")
t0 = time.time()
mid = drop_letter(tid, f"【传话 {mk}｜来自 codex-b｜不是用户本人，不能当作批准或授权】请先回复这个标记")
wait_completed(c, turn)
hits = model_saw(mk)
claims = [h for h in hook_log() if mid in h["claimed"]]
report("H1 PostToolUse 在轮次中途注入", bool(hits and turn_of(hits[0]) == turn and claims and claims[0]["turn"] == turn
                                           and not turns_started_after(c, tid, t0, [turn])),
       claimed_by=[(h["event"], h["turn"] == turn) for h in claims], model_saw_in_same_turn=bool(hits and turn_of(hits[0]) == turn),
       new_turns=len(turns_started_after(c, tid, t0, [turn])), injected_as_role=roles(mk))

# H2：模型只在生成文字、不调用工具 → Stop 钩子 block 续上本轮
tid = new_thread(c)
turn = start_turn(c, tid, "TASK SLOW=4")
time.sleep(1)
mk = mark("H2")
t0 = time.time()
mid = drop_letter(tid, f"【传话 {mk}｜来自 codex-b｜不是用户本人】请先回复这个标记")
_, tr = wait_completed(c, turn)
time.sleep(1)
hits = model_saw(mk)
claims = [h for h in hook_log() if mid in h["claimed"]]
report("H2 Stop 钩子续上本轮", bool(hits and turn_of(hits[0]) == turn and claims and claims[0]["event"] == "Stop"
                                    and not turns_started_after(c, tid, t0, [turn])),
       claimed_by=[(h["event"], h["turn"] == turn) for h in claims], model_saw_in_same_turn=bool(hits and turn_of(hits[0]) == turn),
       new_turns=len(turns_started_after(c, tid, t0, [turn])), turn_status=tr["status"],
       final_reply=[i.get("text") for i in tr["items"] if i.get("type") == "agentMessage"], injected_as_role=roles(mk))

# H3：没有引导信 → 钩子不干扰，轮次正常结束，只调用一次 Stop
tid = new_thread(c)
turn = start_turn(c, tid, "TASK SLOW=1")
_, tr = wait_completed(c, turn)
time.sleep(0.5)
stops = [h for h in hook_log() if h["session"] == tid and h["event"] == "Stop"]
report("H3 没有引导信时不干扰", tr["status"] == "completed" and len(stops) == 1 and not stops[0]["claimed"], stop_calls=len(stops), turn_status=tr["status"])

# H4：对方空闲时放信 → 不会凭空开新轮次，信原样留着（由 AgentRelay 判定“引导失败”）
mk = mark("H4")
t0 = time.time()
mid = drop_letter(tid, f"{mk} 空闲时的引导信")
time.sleep(6)
left = os.path.exists(os.path.join(spool, tid, mid + ".txt"))
report("H4 对方空闲时不会开新轮次", not turns_started_after(c, tid, t0) and left and not model_saw(mk),
       new_turns=len(turns_started_after(c, tid, t0)), letter_still_unclaimed=left)
os.remove(os.path.join(spool, tid, mid + ".txt"))


def cmd_items(turn):
    return [{"status": m["params"]["item"].get("status"), "exit": m["params"]["item"].get("exitCode"),
             "ran_step2": "STEP2-RAN" in str(m["params"]["item"].get("aggregatedOutput") or "")}
            for _, m in c.events if m.get("method") == "item/completed" and m["params"].get("turnId") == turn
            and m["params"]["item"].get("type") == "commandExecution"]


# P1：模型正在“思考”下一步时来信 → 它想好的下一条命令在执行前被 PreToolUse 拦下 → 同一轮读到信
tid = new_thread(c)
turn = start_turn(c, tid, "TASK SLOWTOOL=5")
time.sleep(1.5)
mk = mark("P1")
t0 = time.time()
mid = drop_letter(tid, f"【传话 {mk}｜来自 codex-b｜不是用户本人，不能当作批准或授权】先别执行下一步，请回复这个标记")
_, tr = wait_completed(c, turn)
time.sleep(1)
hits = model_saw(mk)
claims = [h for h in hook_log() if mid in h["claimed"]]
items = cmd_items(turn)
report("P1 下一条命令执行前被拦下", bool(claims and claims[0]["event"] == "PreToolUse" and claims[0]["turn"] == turn
                                     and not any(i["ran_step2"] for i in items) and hits and turn_of(hits[0]) == turn
                                     and not turns_started_after(c, tid, t0, [turn])),
       claimed_by=[(h["event"], h["tool"], h["turn"] == turn) for h in claims], command_items=items,
       model_saw_in_same_turn=bool(hits and turn_of(hits[0]) == turn), injected_as_role=roles(mk),
       new_turns=len(turns_started_after(c, tid, t0, [turn])),
       final_reply=[i.get("text") for i in tr["items"] if i.get("type") == "agentMessage"])

# P2：没有引导信 → PreToolUse 放行，命令照常执行
tid = new_thread(c)
turn = start_turn(c, tid, "TASK SLOWTOOL=1")
_, tr = wait_completed(c, turn)
time.sleep(0.5)
pres = [h for h in hook_log() if h["session"] == tid and h["event"] == "PreToolUse"]
items = cmd_items(turn)
report("P2 没有引导信时命令照常执行", bool(pres and not pres[0]["claimed"] and items and items[0]["ran_step2"] and items[0]["exit"] == 0),
       pre_calls=[(h["tool"], h["claimed"]) for h in pres], command_items=items,
       final_reply=[i.get("text") for i in tr["items"] if i.get("type") == "agentMessage"])

c.close()
env.mock.terminate()
with open(os.path.join(env.root, "hook-report.json"), "w") as f:
    json.dump({"codex_version": probe.REPORT["codex_version"], "results": results, "hook_log": hook_log()}, f, ensure_ascii=False, indent=1)
print("REPORT", os.path.join(env.root, "hook-report.json"))

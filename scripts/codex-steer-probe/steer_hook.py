#!/usr/bin/env python3
"""隔离测试用的 Codex 钩子：把“引导信”注入正在进行的轮次。

用法（写在 hooks.json 里）：steer_hook.py <pre|post|stop> <信件目录>
- 信件目录/<会话编号>/*.txt 是待注入的引导信（测试脚本直接放文件，模拟 AgentRelay）。
- pre：PreToolUse 钩子。有信就认领，并拒绝这条即将执行的命令（permissionDecision=deny），
       信的内容作为拒绝理由，以工具结果的形式交给模型。名字含 relay_ 的工具（AgentRelay 自己的）不拦。
- post：PostToolUse 钩子。有信就认领（改名为 .claimed）并通过 additionalContext 注入。
- stop：Stop 钩子。轮次要结束时还有没送到的信，就 decision=block，用 reason 让本轮继续。
每次调用都在 信件目录/hook-log.jsonl 记一行（事件、会话、轮次、工具名、认领了哪些信）。
"""
import json, os, sys, time

mode, spool = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
sid, turn = data.get("session_id", ""), data.get("turn_id", "")
tool = str(data.get("tool_name") or "")
box = os.path.join(spool, sid)
claimed, texts = [], []
if os.path.isdir(box) and not (mode == "pre" and "relay_" in tool):
    for name in sorted(os.listdir(box)):
        if not name.endswith(".txt"):
            continue
        src = os.path.join(box, name)
        dst = src[:-4] + f".claimed-{turn}"
        try:
            os.rename(src, dst)  # 原子认领：同一封信只会被一次钩子调用拿到
        except FileNotFoundError:
            continue
        with open(dst, encoding="utf-8") as f:
            texts.append(f.read())
        claimed.append(name[:-4])
with open(os.path.join(spool, "hook-log.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps({"t": time.time(), "event": data.get("hook_event_name"), "session": sid, "turn": turn, "tool": tool,
                        "stop_hook_active": data.get("stop_hook_active"), "claimed": claimed}, ensure_ascii=False) + "\n")
if not texts:
    print("{}")
elif mode == "pre":
    reason = "有一封引导信，请先按信的内容重新考虑，再决定是否继续刚才这一步。信的内容：" + "\n\n".join(texts)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}, ensure_ascii=False))
elif mode == "post":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "\n\n".join(texts)}}, ensure_ascii=False))
else:
    print(json.dumps({"decision": "block", "reason": "\n\n".join(texts)}, ensure_ascii=False))

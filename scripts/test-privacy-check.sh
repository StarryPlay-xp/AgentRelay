#!/bin/bash
# 隐私检查的自测：在临时仓库里故意放入各类样例，确认钩子该拦的拦、该放的放。
# 样例在运行时拼出来，本文件本身不含任何会被拦下的字面值。
# 用法：scripts/test-privacy-check.sh    全部通过退出 0，否则退出 1。

set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/privacy-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

cd "$T" || exit 2
git init -q -b main .
git config user.name "privacy-test"
git config user.email "privacy-test@example.com"
mkdir -p scripts .githooks
cp "$SRC/scripts/privacy-check.sh" scripts/
cp "$SRC/.githooks/pre-commit" "$SRC/.githooks/commit-msg" .githooks/
chmod +x scripts/privacy-check.sh .githooks/*
git config core.hooksPath .githooks
printf '%s\n' 'secret''corp' > .privacy-denylist
printf '%s\n' '.privacy-denylist' > .gitignore
git add scripts .githooks .gitignore
git commit -q -m "test: 初始化" || { echo "初始化提交失败"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  通过  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  失败  %s\n' "$1"; }

# 暂存一个文件并尝试提交；$1 说明，$2 期望（block/pass），$3 内容，$4 提交说明（可选）
try_commit() {
    name="$1"; expect="$2"; body="$3"; msg="${4:-test: 样例}"
    printf '%s\n' "$body" > sample.txt
    git add sample.txt
    if git commit -q -m "$msg" > "$T/out" 2>&1; then got=pass; else got=block; fi
    if [ "$got" = "$expect" ]; then ok "$name"; else bad "$name（期望 $expect，实际 $got）"; cat "$T/out"; fi
    if [ "$got" = block ]; then git reset -q; rm -f sample.txt; fi
}

u='/Users'
user=$(id -un)
uuid=$(uuidgen | tr 'A-Z' 'a-z')
k1='-----BEGIN'; k2=' PRIVATE KEY-----'
gh='gh''p_'; tok=$(printf 'a%.0s' $(seq 1 36))
team='DEVELOPMENT''_TEAM'
at='@'

echo "隐私检查自测："
try_commit "本机家目录路径"        block "路径 $HOME/x"
try_commit "真实用户路径"          block "路径 $u/someone/x"
try_commit "占位用户路径"          pass  "路径 $u/<用户名>/x"
try_commit "/Users/Shared"         pass  "路径 $u/Shared/x"
try_commit "本机用户名"            block "作者 $user"
try_commit "随机会话编号"          block "编号 $uuid"
try_commit "固定示例编号"          pass  "编号 00000000-0000-4000-8000-000000000001"
try_commit "桌面版会话编号"        block "编号 local_""0123abcd"
try_commit "私钥开头"              block "$k1$k2"
try_commit "平台令牌"              block "令牌 $gh$tok"
try_commit "内网 IP"               block "地址 10.1"".2.3"
try_commit "本机回环地址"          pass  "地址 127.0.0.1"
try_commit "文档示例 IP"           pass  "地址 192.0.2.10"
try_commit "电子邮箱"              block "邮箱 someone${at}corp-mail.cn"
try_commit "示例邮箱"              pass  "邮箱 someone${at}example.com"
try_commit "团队编号"              block "$team = ABCDE12345;"
try_commit "空团队编号"            pass  "$team = \"\";"
try_commit "私有词表"              block "公司 SECRET""CORP"
try_commit "普通内容"              pass  "普通的设计说明，路径写成 ~/.agentrelay/run/"
try_commit "提交说明含家目录"      block "普通内容 2" "docs: 修改 $HOME/x"

# 历史检查：用 --no-verify 绕过钩子放进一条命中，--history 必须报出来
printf '%s\n' "编号 $uuid" > leaked.txt
git add leaked.txt
git commit -q --no-verify -m "test: 故意绕过" 2>/dev/null
if scripts/privacy-check.sh --history > "$T/out" 2>&1; then
    bad "历史检查（应报出绕过钩子的提交）"
else
    if grep -q '疑似会话编号' "$T/out" && ! grep -q "$uuid" "$T/out"; then
        ok "历史检查报出命中且不回显内容"
    else
        bad "历史检查输出不符合预期"; cat "$T/out"
    fi
fi

echo "结果：通过 $pass 项，失败 $fail 项"
[ "$fail" -eq 0 ]

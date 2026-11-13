#!/bin/bash
# AgentRelay 隐私检查：在提交和公开推送前，拦住个人隐私进入仓库。
# 规则见 README.md 的“隐私约定”。只报告位置和命中类型，不回显命中的内容。
#
# 用法：
#   scripts/privacy-check.sh --staged            检查暂存区里新增的行和文件名（pre-commit 钩子使用）
#   scripts/privacy-check.sh --message <文件>    检查提交说明（commit-msg 钩子使用）
#   scripts/privacy-check.sh --files             检查工作区里所有已跟踪和未忽略的文本文件
#   scripts/privacy-check.sh --history [范围]    检查全部（或指定范围的）提交内容和提交说明
#
# 本机私有词表：仓库根目录的 .privacy-denylist（不进仓库），一行一个词，不区分大小写。
# 允许清单：仓库根目录的 .privacy-allowlist（进仓库），一行一个精确字符串，用于放行误报。
#
# 退出码：0 没有命中；1 有命中；2 用法或环境错误。
# 兼容 macOS 自带的 bash 3.2、BSD grep 和 BSD awk。

set -u

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

[ $# -ge 1 ] || usage

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "privacy-check：不在 Git 仓库里" >&2; exit 2; }
DENYLIST="$ROOT/.privacy-denylist"
ALLOWLIST="$ROOT/.privacy-allowlist"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/privacy-check.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
CONTENT="$WORK/content"   # 待检查的文本，每行一条
LOCATION="$WORK/location" # 与 CONTENT 逐行对应的位置说明
HITS="$WORK/hits"
: > "$CONTENT"; : > "$LOCATION"; : > "$HITS"

GIT="git -c core.quotepath=false"

# 把统一格式差异（-U0）里新增的行收集到 CONTENT，位置写成“前缀文件:行号”
collect_diff() {
    prefix="$1"
    awk -v prefix="$prefix" -v content="$CONTENT" -v location="$LOCATION" '
        /^\+\+\+ / {
            f = substr($0, 5); sub(/^b\//, "", f); next
        }
        /^@@/ {
            if (match($0, /\+[0-9]+/)) { ln = substr($0, RSTART + 1, RLENGTH - 1) + 0 }
            next
        }
        /^\+/ {
            print substr($0, 2) >> content
            print prefix f ":" ln >> location
            ln++
            next
        }
    '
}

# 把一个文件（或标准输入）的每一行收集到 CONTENT，位置写成“标签:行号”
collect_lines() {
    label="$1"
    awk -v label="$label" -v content="$CONTENT" -v location="$LOCATION" '
        { print $0 >> content; print label ":" NR >> location }
    '
}

mode="$1"; shift
case "$mode" in
    --staged)
        $GIT diff --cached -U0 --no-color --no-ext-diff --diff-filter=ACMR | collect_diff ""
        $GIT diff --cached --name-only --diff-filter=ACMR | collect_lines "（暂存的文件名）"
        ;;
    --message)
        [ $# -eq 1 ] && [ -f "$1" ] || usage
        grep -v '^#' "$1" | collect_lines "（提交说明）"
        ;;
    --files)
        $GIT ls-files -co --exclude-standard > "$WORK/files"
        while IFS= read -r f; do
            [ -f "$ROOT/$f" ] || continue
            grep -Iq . "$ROOT/$f" 2>/dev/null || continue   # 跳过二进制和空文件
            collect_lines "$f" < "$ROOT/$f"
            printf '%s\n' "$f" | collect_lines "（文件名）$f"
        done < "$WORK/files"
        ;;
    --history)
        range="${1:---all}"
        if ! git rev-parse --verify -q HEAD >/dev/null; then
            echo "privacy-check：还没有任何提交"; exit 0
        fi
        git rev-list $range > "$WORK/commits" || exit 2
        while IFS= read -r c; do
            short=$(git rev-parse --short "$c")
            $GIT diff-tree -p -U0 --no-color --no-ext-diff --root -m --first-parent --no-commit-id "$c" \
                | collect_diff "提交 $short "
            git log -1 --format=%B "$c" | collect_lines "提交 $short（提交说明）"
        done < "$WORK/commits"
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage
        ;;
esac

[ -s "$CONTENT" ] || exit 0

# 精确放行的字符串：内置的示例值 + 仓库里的允许清单
ALLOW="$WORK/allow"
{
    printf '%s\n' 127.0.0.1 0.0.0.0
    [ -f "$ALLOWLIST" ] && grep -v '^[[:space:]]*#' "$ALLOWLIST" | grep -v '^[[:space:]]*$'
} > "$ALLOW"

# 记录一条命中：行号（CONTENT 中的） + 类型
hit() { printf '%s\t%s\n' "$1" "$2" >> "$HITS"; }

# 按“逐个匹配”检查，放行清单里的值和额外的放行规则
check_matches() {
    type="$1"; pattern="$2"; extra_allow="${3:-}"
    grep -n -o -E -e "$pattern" "$CONTENT" 2>/dev/null > "$WORK/m" || return 0
    while IFS= read -r line; do
        n=${line%%:*}; value=${line#*:}
        if grep -qxF -e "$value" "$ALLOW"; then continue; fi
        if [ -n "$extra_allow" ] && printf '%s\n' "$value" | grep -qE -e "$extra_allow"; then continue; fi
        hit "$n" "$type"
    done < "$WORK/m"
}

# 按“整行”检查
check_lines() {
    type="$1"; shift
    grep -n "$@" "$CONTENT" 2>/dev/null | cut -d: -f1 > "$WORK/l" || return 0
    while IFS= read -r n; do hit "$n" "$type"; done < "$WORK/l"
}

USER_NAME=$(id -un)

# 1. 当前用户的家目录路径和用户名
check_lines "本机家目录路径" -F -e "$HOME"
check_lines "本机用户名" -w -i -F -e "$USER_NAME"
# 2. /Users/ 后面跟着真实名字（占位 /Users/<用户名> 和 /Users/Shared 除外）
check_matches "真实用户路径" '/Users/[A-Za-z0-9._-]+' '^/Users/Shared$'
# 3. 会话编号一类的长串（固定示例 00000000-0000-4000-8000-0000000000NN 除外）
check_matches "疑似会话编号" '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
    '^00000000-0000-4000-8000-0000000000[0-9][0-9]$'
check_matches "疑似桌面版会话编号" 'local_[0-9A-Fa-f]{8}'
# 4. 私钥、令牌
check_lines "私钥" -E -e '-----BEGIN [A-Z ]*PRIVATE KEY-----'
check_matches "疑似令牌" '(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|gh[ousr]_[A-Za-z0-9]{36}|sk-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})'
# 5. IP 地址（文档专用示例段除外）
check_matches "IP 地址" '([0-9]{1,3}\.){3}[0-9]{1,3}' '^(192\.0\.2|198\.51\.100|203\.0\.113)\.'
# 6. 电子邮箱（示例域名、noreply、git@ 除外）
check_matches "电子邮箱" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
    '(@example\.(com|org|net)$|\.(test|example|invalid)$|^noreply@|^git@)'
# 7. Apple 开发者团队编号
check_lines "开发者团队编号" -E -e 'DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*"?[A-Z0-9]{10}'
# 8. 本机私有词表
if [ -f "$DENYLIST" ]; then
    grep -v '^[[:space:]]*#' "$DENYLIST" | grep -v '^[[:space:]]*$' > "$WORK/deny"
    [ -s "$WORK/deny" ] && check_lines "私有词表" -i -F -f "$WORK/deny"
fi

[ -s "$HITS" ] || exit 0

echo "privacy-check：发现可能的个人隐私，已拒绝。下面只列位置和类型："
sort -t "$(printf '\t')" -k1,1n -u "$HITS" | while IFS="$(printf '\t')" read -r n type; do
    loc=$(sed -n "${n}p" "$LOCATION")
    printf '  %s  [%s]\n' "$loc" "$type"
done
echo "改成占位写法（见 README.md 的“隐私约定”）后再试；确属误报时，把精确字符串加进 .privacy-allowlist。"
exit 1

#!/bin/bash
# 只在两种情况下处理：本地 master 落后于官方仓库 gfwlist/gfwlist 的 master，
# 或 publish 上有新的手工提交（如修改了 custom-domains.txt）；否则直接结束。
# master 落后时先快进过去，并（--push 时）立即推送到 fork；
# 之后只以本地 master 为基础，合并 custom-domains.txt，重新生成 gfwlist.txt，
# 并以新修订的形式提交到对外服务分支（默认 publish）。
#
# 每次运行产生一个提交：树 = master 内容 + 自定义规则，
# 父提交 = [上次的 publish, master]；master 没有新提交时只有上次的 publish，历史保持直线。
# 因此不会有冲突，历史可追溯，推送为快进。
#
# 用法: ./build-publish.sh [--push]
# 环境变量: UPSTREAM_URL=https://github.com/gfwlist/gfwlist.git  UPSTREAM_BRANCH=master
#           REMOTE=origin  PUBLISH=publish  CUSTOM=custom-domains.txt
#           MASTER=master
# 上游直接按 URL 拉取（不添加 remote），推送到 REMOTE（自己的 fork）。
# master 只做快进，非快进由 git 拒绝并报错退出，不会强推。
set -euo pipefail

cd "$(dirname "$0")"
root=$(pwd)
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/gfwlist/gfwlist.git}
UPSTREAM_BRANCH=${UPSTREAM_BRANCH:-master}
REMOTE=${REMOTE:-origin}
PUBLISH=${PUBLISH:-publish}
CUSTOM=${CUSTOM:-custom-domains.txt}
MASTER=${MASTER:-master}
MSG="gfwlist + custom rules"  # 脚本生成的提交标题，也用来判断 publish 有无新的手工提交

PUSH=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    *) echo "Usage: $0 [--push]"; exit 1 ;;
  esac
done

for cmd in date file git openssl perl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: You must have $cmd command installed!"; exit 1; }
done
[ -f "$CUSTOM" ] || { echo "Error: $CUSTOM not found"; exit 1; }
[ -f README-publish.md ] || { echo "Error: README-publish.md not found"; exit 1; }
[ -f apollyon/addChecksum.pl ] || git submodule update --init apollyon

# 1. 本地 MASTER 落后于官方 master 时快进，--push 时立即推送到 REMOTE；此后只以本地 MASTER 为基础。
#    MASTER 不落后、PUBLISH 也没有新的手工提交（最新提交仍是本脚本生成的）时直接结束。
git fetch -q "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
UPSTREAM=$(git rev-parse FETCH_HEAD)
if git rev-parse -q --verify "refs/heads/$MASTER" >/dev/null &&
   git merge-base --is-ancestor "$UPSTREAM" "refs/heads/$MASTER"; then
  if git rev-parse -q --verify "refs/heads/$PUBLISH" >/dev/null &&
     [ "$(git log -1 --format=%s "refs/heads/$PUBLISH")" = "$MSG" ]; then
    echo "$MASTER is not behind upstream and $PUBLISH has no new commits, nothing to do."
    exit 0
  fi
elif [ "$(git symbolic-ref -q --short HEAD || true)" = "$MASTER" ]; then
  git merge -q --ff-only "$UPSTREAM" || { echo "Error: $MASTER cannot be fast-forwarded to upstream"; exit 1; }
else
  git fetch -q . "$UPSTREAM:refs/heads/$MASTER" || { echo "Error: $MASTER cannot be fast-forwarded to upstream"; exit 1; }
fi
if [ "$PUSH" = 1 ]; then
  git push "$REMOTE" "$MASTER"
fi
BASE=$(git rev-parse "refs/heads/$MASTER")

work=$(mktemp -d)
cleanup() { git worktree remove --force "$work/wt" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

git worktree add -q --detach "$work/wt" "$BASE"
cd "$work/wt"

# 2. 合并自定义规则：跳过已存在的，仿照 list.txt 的分段格式包在 Custom List Start/End 之间，插在 EOF 注释行之前
grep -v '^[[:space:]]*$' "$root/$CUSTOM" | grep -v '^!' > "$work/rules" || true
: > "$work/new"
while IFS= read -r rule; do
  grep -qxF -- "$rule" list.txt || echo "$rule" >> "$work/new"
done < "$work/rules"
if [ -s "$work/new" ]; then
  {
    echo '!###############Custom List Start###############'
    cat "$work/new"
    echo '!################Custom List End################'
  } > "$work/block"
  mv "$work/block" "$work/new"
  eof=$(grep -n '^!-*EOF-*$' list.txt | tail -1 | cut -d: -f1 || true)
  if [ -n "$eof" ]; then
    { head -n $((eof-1)) list.txt; cat "$work/new"; tail -n +"$eof" list.txt; } > "$work/list.txt"
  else
    { cat list.txt; cat "$work/new"; } > "$work/list.txt"
  fi
  mv "$work/list.txt" list.txt
fi

# 3. 与 workflow 相同：更新日期/checksum（在副本上做，不污染 list.txt）并转 base64
cp list.txt "$work/check.txt"
# Last Modified 取 master 提交时间而非当前时间，保证无变化时结果可重复
touch -d "@$(git log -1 --format=%ct "$BASE")" "$work/check.txt"
perl "$root/apollyon/addChecksum.pl" "$work/check.txt" || { echo "Error: Failed to update checksum"; exit 1; }
if [ "$(file -b "$work/check.txt" | grep -o "ASCII text")" != "ASCII text" ]; then
  echo "Error: list.txt invalid, please make sure:"
  echo "1. there is no non-ASCII characters;"
  echo "2. configure your text editor to use unix style line break."
  exit 1
fi
openssl base64 -in "$work/check.txt" | tr -d '\r' > gfwlist.txt

# 4. 把脚本、说明和自定义规则一并放进 publish，使该分支可独立执行本脚本
cp -p "$root/build-publish.sh" build-publish.sh
cp "$root/README-publish.md" README-publish.md
[ "$root/$CUSTOM" -ef custom-domains.txt ] || cp "$root/$CUSTOM" custom-domains.txt

# 5. 提交为新修订
git add list.txt gfwlist.txt build-publish.sh README-publish.md custom-domains.txt
tree=$(git write-tree)
# 父提交：上次的 PUBLISH；MASTER 有 PUBLISH 尚未包含的新提交时再加上 MASTER，否则保持直线
if git rev-parse -q --verify "refs/heads/$PUBLISH" >/dev/null; then
  parents=(-p "$(git rev-parse "refs/heads/$PUBLISH")")
  git merge-base --is-ancestor "$BASE" "refs/heads/$PUBLISH" || parents+=(-p "$(git rev-parse "$BASE")")
else
  parents=(-p "$(git rev-parse "$BASE")")
fi
commit=$(git commit-tree "$tree" "${parents[@]}" -m "$MSG")
if [ "$(git -C "$root" symbolic-ref -q --short HEAD || true)" = "$PUBLISH" ]; then
  # 正在 publish 分支上运行：工作区必须干净，再同步到新提交
  git -C "$root" diff --quiet HEAD || { echo "Error: working tree is dirty"; exit 1; }
  git -C "$root" reset -q --hard "$commit"
else
  git update-ref "refs/heads/$PUBLISH" "$commit"
fi
echo "$PUBLISH -> $(git rev-parse --short "$commit"): $MSG"

# 6. 推送 publish
if [ "$PUSH" = 1 ]; then
  git push "$REMOTE" "$PUBLISH"
fi

#!/usr/bin/env bash
# 在临时仓库和临时配置目录里验证 install.sh，不碰本机配置。需要 jq。
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
root="$(mktemp -d "${TMPDIR:-/tmp}/agent-kit-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT

checks=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -f "$root/output" ] || cat "$root/output" >&2
  exit 1
}
check() { # check <说明> <命令...>
  local label="$1"
  shift
  "$@" || fail "$label"
  checks=$((checks + 1))
}
mode() { ls -ld "$1" | cut -c1-10; }

repo="$root/repo with spaces"
claude="$root/claude home"
codex="$root/codex home"
run() { # CODEX_HOME 带结尾斜杠，顺带验证路径规整
  CLAUDE_CONFIG_DIR="$claude" CODEX_HOME="$codex/" "$BASH" "$repo/install.sh" "$@" > "$root/output" 2>&1
}
expect_failure() {
  if run "$@"; then fail "应当失败：install.sh $*"; fi
  checks=$((checks + 1))
}

# 最小仓库：两个 skill、一个第三方 skill、一个嵌套配置和一个应被跳过的隐藏文件。
mkdir -p "$repo/claude/plugins/hud" "$repo/codex" "$repo/vendor/skills/gamma"
cp "$src/install.sh" "$repo/"
printf '# Instructions\n' > "$repo/instructions.md"
printf '{"theme":"dark"}\n' > "$repo/claude/settings.json"
printf '{}\n' > "$repo/claude/plugins/hud/config.json"
printf 'model_provider = "cm"\n' > "$repo/codex/config.toml"
printf 'junk\n' > "$repo/codex/.DS_Store"
for name in alpha beta; do
  mkdir -p "$repo/skills/$name"
  printf '# %s\n' "$name" > "$repo/skills/$name/SKILL.md"
done
printf '# gamma\n' > "$repo/vendor/skills/gamma/SKILL.md"

# 全新安装：两边都是副本，key 为空；回滚后不留文件。
run || fail '全新安装失败'
check '安装 Claude 指令' cmp "$repo/instructions.md" "$claude/CLAUDE.md"
check '安装 Codex 指令' cmp "$repo/instructions.md" "$codex/AGENTS.md"
check '安装 Claude 配置' cmp "$repo/claude/settings.json" "$claude/settings.json"
check '嵌套配置按相对路径安装' cmp "$repo/claude/plugins/hud/config.json" "$claude/plugins/hud/config.json"
check '安装 Codex 配置' cmp "$repo/codex/config.toml" "$codex/config.toml"
check 'Claude 有 skill' cmp "$repo/skills/beta/SKILL.md" "$claude/skills/beta/SKILL.md"
check 'Codex 有 skill' cmp "$repo/skills/beta/SKILL.md" "$codex/skills/beta/SKILL.md"
check '跳过隐藏文件' test ! -e "$codex/.DS_Store"
check '第三方 skill 默认不装' test ! -e "$codex/skills/gamma"
check '空 key' jq -e '. == {auth_mode: "apikey", OPENAI_API_KEY: ""}' "$codex/auth.json" > /dev/null
check '没有符号链接' test -z "$(find "$claude" "$codex" -type l)"
check 'auth.json 权限' test "$(mode "$codex/auth.json")" = '-rw-------'
check '安装记录权限' test "$(mode "$codex/.agent-kit")" = 'drwx------'
run -r || fail '回滚全新安装失败'
check '回滚后不留文件' test -z "$(find "$claude" "$codex" ! -type d)"
check '回滚清理安装记录' test ! -e "$codex/.agent-kit"
expect_failure -r

# 已有配置：第一次接管时存原样，之后重装不覆盖；回滚全部放回。
mkdir -p "$claude/skills/alpha" "$codex/skills/mine" "$codex/sessions" "$root/external"
printf 'local\n' > "$claude/settings.json"
printf '# my alpha\n' > "$claude/skills/alpha/SKILL.md"
printf 'notes\n' > "$claude/skills/alpha/notes.md"
printf 'outside\n' > "$root/external/config"
ln -s "$root/external/config" "$codex/config.toml"
printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"t"}}' > "$codex/auth.json"
cp "$codex/auth.json" "$root/chatgpt-auth"
printf '# mine\n' > "$codex/skills/mine/SKILL.md"
printf 'data\n' > "$codex/sessions/keep.jsonl"

key=$'test-"key"\\path\tline\nnext\r\001中文'
run --cm-key "$key" || fail '覆盖安装失败'
if grep -q 'test-"key"' "$root/output"; then fail '输出里出现了 key'; fi
check 'key 转义正确' jq -e --arg key "$key" '. == {auth_mode: "apikey", OPENAI_API_KEY: $key}' "$codex/auth.json" > /dev/null
check '替换同名配置' cmp "$repo/claude/settings.json" "$claude/settings.json"
check '同名 skill 整个替换' test ! -e "$claude/skills/alpha/notes.md"
check '链接换成普通文件' test -f "$codex/config.toml" -a ! -L "$codex/config.toml"
check '不顺着链接写' test "$(cat "$root/external/config")" = outside
check '不动无关 skill' test -f "$codex/skills/mine/SKILL.md"
check '不动会话' test -f "$codex/sessions/keep.jsonl"

cp "$codex/auth.json" "$root/keyed-auth"
printf 'edited\n' > "$claude/settings.json"
run || fail '重装失败'
check '重装保留 CodexManager key' cmp "$root/keyed-auth" "$codex/auth.json"
check '重装覆盖本机改动' cmp "$repo/claude/settings.json" "$claude/settings.json"
check '原样只存一次' test "$(cat "$claude/.agent-kit/original/settings.json")" = local
run codex --cm-key replacement || fail '指定 key 重装失败'
check '--cm-key 覆盖已有 key' jq -e '.OPENAI_API_KEY == "replacement"' "$codex/auth.json" > /dev/null
for auth in '{"auth_mode":"chatgpt","OPENAI_API_KEY":"old"}' '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-official"}'; do
  printf '%s\n' "$auth" > "$codex/auth.json"
  run codex || fail '重装失败'
  check "不保留 $auth" jq -e '. == {auth_mode: "apikey", OPENAI_API_KEY: ""}' "$codex/auth.json" > /dev/null
done

# 仓库里删掉的 skill 放回原样；要不要第三方 skill，每台机器记住上次的选择。
mv "$repo/skills/alpha" "$root/alpha"
run --with-vendor || fail '带 --with-vendor 重装失败'
check '删掉的 skill 恢复本机原样' test -f "$claude/skills/alpha/notes.md"
check '删掉的 skill 原本没有就移除' test ! -e "$codex/skills/alpha"
check '装上第三方 skill' cmp "$repo/vendor/skills/gamma/SKILL.md" "$claude/skills/gamma/SKILL.md"
run --without-vendor || fail '带 --without-vendor 重装失败'
check '--without-vendor 移除第三方 skill' test ! -e "$claude/skills/gamma"
run || fail '不带参数重装失败'
check '记住不要第三方 skill' test ! -e "$claude/skills/gamma"
mv "$root/alpha" "$repo/skills/alpha"
run --with-vendor || fail '加回 skill 后重装失败'
check '重新接管同名 skill' test ! -e "$claude/skills/alpha/notes.md"
run || fail '不带参数重装失败'
check '记住要第三方 skill' test -f "$codex/skills/gamma/SKILL.md"

run -r || fail '回滚失败'
check '恢复原配置' test "$(cat "$claude/settings.json")" = local
check '恢复原 skill' test -f "$claude/skills/alpha/notes.md"
check '恢复原链接' test "$(readlink "$codex/config.toml")" = "$root/external/config"
check '恢复原登录' cmp "$root/chatgpt-auth" "$codex/auth.json"
check '删除原本没有的文件' test ! -e "$claude/CLAUDE.md"
check '不动无关 skill' test -f "$codex/skills/mine/SKILL.md"
check '清理安装记录' test ! -e "$claude/.agent-kit" -a ! -e "$codex/.agent-kit"

# 只装 Claude 时不碰 Codex；回滚会忘掉第三方 skill 的选择；无效参数直接退出。
codex="$root/untouched codex"
run claude || fail '只装 Claude 失败'
check '只装 Claude 时不碰 Codex' test ! -e "$codex"
check '回滚后不再记得第三方 skill' test ! -e "$claude/skills/gamma"
expect_failure --cm-key
expect_failure claude --cm-key key
expect_failure -r --with-vendor
expect_failure --with-vendor --without-vendor
expect_failure --unknown

# 真实仓库：装完删掉仓库，配置照样完整。
copy="$root/real repo"
mkdir "$copy"
cp -R "$src/install.sh" "$src/instructions.md" "$src/claude" "$src/codex" "$src/skills" "$src/vendor" "$copy/"
repo="$copy" claude="$root/real claude" codex="$root/real codex"
run --with-vendor || fail '安装真实仓库失败'
rm -rf "$copy"
check '真实仓库：没有符号链接' test -z "$(find "$claude" "$codex" -type l)"
check '真实仓库：指令' cmp "$src/instructions.md" "$codex/AGENTS.md"
check '真实仓库：Codex 配置' cmp "$src/codex/config.toml" "$codex/config.toml"
for dir in "$src"/skills/*/ "$src"/vendor/skills/*/; do
  name="$(basename "$dir")"
  check "真实仓库：skill $name" diff -r "$dir" "$claude/skills/$name"
done

printf 'PASS: %s 项检查，覆盖安装、重装、auth.json、skill 增删、第三方 skill、回滚和真实仓库\n' "$checks"

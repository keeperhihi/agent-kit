#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_ROOT="$(mktemp -d "${TEST_TMP_ROOT%/}/agent-kit-codex-sync-test.XXXXXX")"
TEST_REPO="$TEST_ROOT/repo"
TEST_HOME="$TEST_ROOT/home"
CODEX_DIR="$TEST_HOME/.codex"
OVERLAY="$TEST_REPO/codex/config.toml.tmpl"
LOCAL="$CODEX_DIR/config.toml"
BASE="$CODEX_DIR/.agent-kit-state/config.toml"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_REPO/codex" "$TEST_REPO/skills/example" "$CODEX_DIR"
cp "$REPO/install.sh" "$TEST_REPO/install.sh"
printf '%s\n' '# Test instructions' > "$TEST_REPO/codex/AGENTS.md"

fail() { printf '%s\n' "$2" >&2; printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run_install() { # 输出存到 $output，退出码存到 $status
  set +e
  output="$(HOME="$TEST_HOME" /bin/bash "$TEST_REPO/install.sh" --target codex "$@" 2>&1)"
  status=$?
  set -e
}
expect() { case "$output" in *"$1"*) ;; *) fail "$2" "$output" ;; esac; }
reject() { case "$output" in *"$1"*) fail "$2" "$output" ;; esac; }
has_line() { grep -Fx -- "$2" "$1" >/dev/null || fail "$3" "$(cat "$1")"; }
lacks_line() { if grep -Fx -- "$2" "$1" >/dev/null; then fail "$3" "$(cat "$1")"; fi; }
replace_line() { # replace_line <文件> <旧行> <新行>；新行为空时删除该行
  AK_OLD_LINE="$2" AK_NEW_LINE="$3" awk '
    BEGIN { old = ENVIRON["AK_OLD_LINE"]; new = ENVIRON["AK_NEW_LINE"] }
    $0 == old { if (new != "") print new; next } { print }
  ' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

cat > "$OVERLAY" <<'TOML'
# repository overlay
approval_policy = "never"
model_verbosity = "medium"

[model_providers.cm]
name = "cm"
base_url = "http://localhost:48760/v1"

[tui]
status_line = ["model", "dir"]
TOML

# 客户端重写过的本机文件：表头和键名带引号，另有本机独有的 token、子表和信任目录。
cat > "$LOCAL" <<'TOML'
approval_policy = "on-request"
"model_verbosity" = "medium"

["model_providers"."cm"]
"name" = "OpenAI"
experimental_bearer_token = "SECRET-TOKEN"

["model_providers"."cm"."http_headers"]
x-test = "1"

["projects"."/home/me/work"]
trust_level = "trusted"
TOML
cp "$LOCAL" "$TEST_ROOT/local.initial"

# 首次同步：同一张表不能因为写法不同被再追加一份，补上的键要留在带引号的表里。
run_install
[ "$status" -eq 0 ] || fail "first install exited with $status" "$output"
lacks_line "$LOCAL" '[model_providers.cm]' "install appended a duplicate provider table"
cat > "$TEST_ROOT/local.expected" <<'TOML'
approval_policy = "never"
"model_verbosity" = "medium"

["model_providers"."cm"]
"name" = "cm"
experimental_bearer_token = "SECRET-TOKEN"
base_url = "http://localhost:48760/v1"

["model_providers"."cm"."http_headers"]
x-test = "1"

["projects"."/home/me/work"]
trust_level = "trusted"

[tui]
status_line = ["model", "dir"]
TOML
cmp -s "$TEST_ROOT/local.expected" "$LOCAL" || fail "first install produced an unexpected config.toml" "$(diff "$TEST_ROOT/local.expected" "$LOCAL" || true)"
[ -f "$BASE" ] || fail "first install did not record the synced values" "$output"

# 同样的输入用 mawk 跑一遍，结果必须一致（macOS 自带的 awk 也不是 gawk）。
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$TEST_ROOT/mawk-bin" "$TEST_ROOT/home-mawk/.codex"
  ln -s "$(command -v mawk)" "$TEST_ROOT/mawk-bin/awk"
  cp "$TEST_ROOT/local.initial" "$TEST_ROOT/home-mawk/.codex/config.toml"
  HOME="$TEST_ROOT/home-mawk" PATH="$TEST_ROOT/mawk-bin:$PATH" \
    /bin/bash "$TEST_REPO/install.sh" --target codex >/dev/null 2>&1 || true
  cmp -s "$LOCAL" "$TEST_ROOT/home-mawk/.codex/config.toml" ||
    fail "mawk produced a different config.toml" "$(diff "$LOCAL" "$TEST_ROOT/home-mawk/.codex/config.toml" || true)"
  cmp -s "$BASE" "$TEST_ROOT/home-mawk/.codex/.agent-kit-state/config.toml" || fail "mawk produced a different sync record" ""
fi

# 本机改了 approval_policy，仓库改了 model_verbosity。
replace_line "$LOCAL" 'approval_policy = "never"' 'approval_policy = "on-failure"'
replace_line "$OVERLAY" 'model_verbosity = "medium"' 'model_verbosity = "high"'
run_install --status
[ "$status" -eq 1 ] || fail "status should flag the unapplied repository change" "$output"
expect 'model_verbosity 的仓库值 "high" 尚未应用' "status did not report the repository change"
expect 'approval_policy 本机改为 "on-failure"' "status did not report the local change"
expect 'model_providers.cm.experimental_bearer_token' "status did not list local-only keys"
expect 'projects' "status did not list the local-only projects table"
reject 'SECRET-TOKEN' "status printed the value of a local-only key"

run_install
[ "$status" -eq 0 ] || fail "install with one-sided changes exited with $status" "$output"
has_line "$LOCAL" '"model_verbosity" = "high"' "install did not apply the repository change"
has_line "$LOCAL" 'approval_policy = "on-failure"' "install overwrote the local change"

# --pull 写回本机改动，模板里的注释保留。
run_install --pull
[ "$status" -eq 0 ] || fail "pull exited with $status" "$output"
has_line "$OVERLAY" 'approval_policy = "on-failure"' "pull did not write the local change back"
has_line "$OVERLAY" '# repository overlay' "pull dropped a comment from the overlay"
run_install --status
[ "$status" -eq 0 ] || fail "status after pull exited with $status" "$output"
expect 'config.toml 的仓库设置已生效' "status after pull is not in sync"

# 本机删掉的受管键不会被 install 加回来；--pull 从模板中移除。
replace_line "$LOCAL" '"name" = "cm"' ''
run_install
[ "$status" -eq 0 ] || fail "install after a local deletion exited with $status" "$output"
expect 'model_providers.cm.name 本机已删除' "install did not report the local deletion"
lacks_line "$LOCAL" 'name = "cm"' "install re-added a key deleted locally"
run_install --pull
lacks_line "$OVERLAY" 'name = "cm"' "pull did not remove the deleted key from the overlay"

# 跨多行的本机值只报告，不改动。
replace_line "$LOCAL" 'status_line = ["model", "dir"]' 'status_line = ['
replace_line "$LOCAL" 'status_line = [' 'status_line = [
  "model",
]'
cp "$LOCAL" "$TEST_ROOT/local.multiline"
replace_line "$OVERLAY" 'status_line = ["model", "dir"]' 'status_line = ["model"]'
run_install
[ "$status" -eq 1 ] || fail "a multi-line local value should make install exit 1" "$output"
expect 'tui.status_line 本机的值跨多行' "install did not report the multi-line value"
cmp -s "$TEST_ROOT/local.multiline" "$LOCAL" || fail "install changed a file it could not merge safely" "$(cat "$LOCAL")"

printf 'PASS: Codex config.toml sync matches quoted tables and keeps CLI changes\n'

#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_ROOT="$(mktemp -d "${TEST_TMP_ROOT%/}/agent-kit-settings-sync-test.XXXXXX")"
TEST_REPO="$TEST_ROOT/repo"
CONFIG="$TEST_ROOT/config"
OVERLAY="$TEST_REPO/claude/settings.json"
LOCAL="$CONFIG/settings.json"
BASE="$CONFIG/.agent-kit-state/settings.json"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_REPO/claude" "$TEST_REPO/skills/example" "$CONFIG"
cp "$REPO/install.sh" "$TEST_REPO/install.sh"
printf '%s\n' '# Test instructions' > "$TEST_REPO/claude/CLAUDE.md"

fail() { printf '%s\n' "$2" >&2; printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run_install() { # 输出存到 $output，退出码存到 $status
  set +e
  output="$(CLAUDE_CONFIG_DIR="$CONFIG" /bin/bash "$TEST_REPO/install.sh" --target claude "$@" 2>&1)"
  status=$?
  set -e
}
expect() { case "$output" in *"$1"*) ;; *) fail "$2" "$output" ;; esac; }
reject() { case "$output" in *"$1"*) fail "$2" "$output" ;; esac; }
edit_json() { jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
check_json() { jq -e "$2" "$1" >/dev/null || fail "$3" "$(cat "$1")"; }

cat > "$OVERLAY" <<'JSON'
{
  "env": { "DISABLE_TELEMETRY": "1" },
  "theme": "dark",
  "tui": "fullscreen",
  "permissions": { "defaultMode": "bypassPermissions" }
}
JSON
cat > "$LOCAL" <<'JSON'
{
  "env": { "DISABLE_TELEMETRY": "1", "HTTP_PROXY": "http://proxy.local:1" },
  "theme": "light",
  "model": "opus"
}
JSON

# 首次同步以仓库为准，并记下同步记录。
run_install
[ "$status" -eq 0 ] || fail "first install exited with $status" "$output"
check_json "$LOCAL" '.theme == "dark" and .tui == "fullscreen" and .permissions.defaultMode == "bypassPermissions"
  and .model == "opus" and .env.HTTP_PROXY == "http://proxy.local:1"' "first install did not apply the overlay"
check_json "$BASE" '. == {"env":{"DISABLE_TELEMETRY":"1"},"theme":"dark","tui":"fullscreen","permissions":{"defaultMode":"bypassPermissions"}}' \
  "first install did not record the synced values"

# 本机在 CLI 里改了 tui、删了 permissions.defaultMode；仓库改了 theme。
edit_json "$LOCAL" '.tui = "default" | del(.permissions)'
edit_json "$OVERLAY" '.theme = "solarized"'
run_install --status
[ "$status" -eq 1 ] || fail "status should flag the unapplied repository change" "$output"
expect 'theme 的仓库值 "solarized" 尚未应用' "status did not report the repository change"
expect 'tui 本机改为 "default"' "status did not report the local change"
expect 'permissions.defaultMode 本机已删除' "status did not report the local deletion"
expect '本机另有未纳入仓库的键：env.HTTP_PROXY, model' "status did not list local-only keys"
reject 'proxy.local' "status printed the value of a local-only key"

# install 只应用仓库这一边的改动，不覆盖本机的改动和删除。
run_install
[ "$status" -eq 0 ] || fail "install with one-sided changes exited with $status" "$output"
expect 'theme = "solarized"（原为 "dark"）' "install did not report the applied key"
check_json "$LOCAL" '.theme == "solarized" and .tui == "default" and (has("permissions") | not)' \
  "install did not keep the local changes while applying the repository change"

# 两边都改了同一个键：install 跳过并报告冲突。
edit_json "$OVERLAY" '.tui = "windowed"'
run_install
[ "$status" -eq 1 ] || fail "a conflict should make install exit 1" "$output"
expect 'tui 两边都改了：仓库 "windowed"，本机 "default"' "install did not report the conflict"
check_json "$LOCAL" '.tui == "default"' "install overwrote a conflicting local value"

# --pull --dry-run 不写仓库；--pull 以本机为准写回，并清掉空的父对象。
cp "$OVERLAY" "$TEST_ROOT/overlay.before-pull"
run_install --pull --dry-run
cmp -s "$TEST_ROOT/overlay.before-pull" "$OVERLAY" || fail "pull --dry-run wrote the overlay" "$output"
run_install --pull
[ "$status" -eq 0 ] || fail "pull exited with $status" "$output"
check_json "$OVERLAY" '. == {"env":{"DISABLE_TELEMETRY":"1"},"theme":"solarized","tui":"default"}' \
  "pull did not write the local changes back"
run_install --status
[ "$status" -eq 0 ] || fail "status after pull exited with $status" "$output"
expect 'settings.json 的仓库设置已生效' "status after pull is not in sync"

# --force 在冲突时以仓库为准，并先备份本机文件。
edit_json "$LOCAL" '.theme = "contrast"'
edit_json "$OVERLAY" '.theme = "nord"'
run_install --force
[ "$status" -eq 0 ] || fail "--force install exited with $status" "$output"
check_json "$LOCAL" '.theme == "nord"' "--force did not take the repository value"
backup="$(find "$CONFIG/.agent-kit-backups" -type f -path '*/settings.json' | head -1)"
[ -n "$backup" ] || fail "--force did not back up settings.json" "$output"
check_json "$backup" '.theme == "contrast"' "--force backup does not hold the local value"

# 没有同步记录时，--pull 以本机为准，但本机缺少的键不当作删除。
rm -f "$BASE"
edit_json "$LOCAL" '.tui = "compact" | del(.env.DISABLE_TELEMETRY)'
run_install --pull
[ "$status" -eq 0 ] || fail "pull without a sync record exited with $status" "$output"
check_json "$OVERLAY" '.tui == "compact" and .env.DISABLE_TELEMETRY == "1"' \
  "pull without a sync record mishandled local values"

printf 'PASS: Claude settings keep CLI changes and --pull writes them back\n'

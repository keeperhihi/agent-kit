#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_ROOT="$(mktemp -d "${TEST_TMP_ROOT%/}/agent-kit-settings-test.XXXXXX")"
TEST_REPO="$TEST_ROOT/repo"
TEST_CONFIG_DIR="$TEST_ROOT/config"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_REPO/claude" "$TEST_REPO/skills/example" "$TEST_CONFIG_DIR"
cp "$REPO/install.sh" "$TEST_REPO/install.sh"
printf '%s\n' '# Test instructions' > "$TEST_REPO/claude/CLAUDE.md"

cat > "$TEST_REPO/claude/settings.json" <<'JSON'
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "allow": ["Bash(repo *)"]
  },
  "model": "opus[1m]",
  "theme": "dark",
  "disableRemoteControl": true
}
JSON

cat > "$TEST_CONFIG_DIR/settings.json" <<'JSON'
{
  "permissions": {
    "defaultMode": "default",
    "allow": ["Bash(local *)"],
    "ask": ["Bash(git push *)"]
  },
  "model": "sonnet",
  "statusLine": {
    "type": "command",
    "command": "local-status"
  },
  "enabledPlugins": {
    "local@example": true
  }
}
JSON

CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR" /bin/bash "$TEST_REPO/install.sh" \
  --target claude --no-vendor >/dev/null

jq -e '
  .permissions.defaultMode == "bypassPermissions" and
  .permissions.allow == ["Bash(repo *)"] and
  .permissions.ask == ["Bash(git push *)"] and
  .model == "opus[1m]" and
  .theme == "dark" and
  .disableRemoteControl == true and
  .statusLine == {"type":"command","command":"local-status"} and
  .enabledPlugins == {"local@example":true}
' "$TEST_CONFIG_DIR/settings.json" >/dev/null

cp "$TEST_CONFIG_DIR/settings.json" "$TEST_ROOT/settings.before"
output="$(CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR" /bin/bash "$TEST_REPO/install.sh" \
  --target claude --no-vendor 2>&1)"
cmp -s "$TEST_ROOT/settings.before" "$TEST_CONFIG_DIR/settings.json"
case "$output" in
  *"settings.json 的仓库设置已生效"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: repeated install did not report an up-to-date settings overlay\n' >&2
    exit 1
    ;;
esac

output="$(CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR" /bin/bash "$TEST_REPO/install.sh" \
  --target claude --status 2>&1)"
case "$output" in
  *"settings.json 的仓库设置已生效"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: status did not accept machine-local settings alongside the overlay\n' >&2
    exit 1
    ;;
esac

tmp="$TEST_REPO/claude/settings.json.tmp"
jq '.theme = "light"' "$TEST_REPO/claude/settings.json" > "$tmp"
mv "$tmp" "$TEST_REPO/claude/settings.json"
cp "$TEST_CONFIG_DIR/settings.json" "$TEST_ROOT/settings.before-dry-run"
output="$(CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR" /bin/bash "$TEST_REPO/install.sh" \
  --target claude --no-vendor --dry-run 2>&1)"
cmp -s "$TEST_ROOT/settings.before-dry-run" "$TEST_CONFIG_DIR/settings.json"
[ ! -e "$TEST_CONFIG_DIR/.agent-kit-backups" ]
case "$output" in
  *"settings.json 将合并仓库设置"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: dry-run did not report the pending settings merge\n' >&2
    exit 1
    ;;
esac

CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR" /bin/bash "$TEST_REPO/install.sh" \
  --target claude --no-vendor --force >/dev/null
[ -d "$TEST_CONFIG_DIR/.agent-kit-backups" ]
backup_count="$(find "$TEST_CONFIG_DIR/.agent-kit-backups" -type f -path '*/settings.json' | wc -l | tr -d ' ')"
if [ "$backup_count" -ne 1 ]; then
  printf 'FAIL: --force created %s settings backups; expected 1\n' "$backup_count" >&2
  exit 1
fi
legacy_backup_count="$(find "$TEST_CONFIG_DIR" -maxdepth 1 -type f -name 'settings.json.bak.*' | wc -l | tr -d ' ')"
[ "$legacy_backup_count" -eq 0 ]
backup_file="$(find "$TEST_CONFIG_DIR/.agent-kit-backups" -type f -path '*/settings.json' | head -1)"
jq -e '.theme == "dark" and .statusLine.command == "local-status"' \
  "$backup_file" >/dev/null
jq -e '.theme == "light" and .statusLine.command == "local-status"' \
  "$TEST_CONFIG_DIR/settings.json" >/dev/null

printf '%s\n' '{invalid json' > "$TEST_CONFIG_DIR/settings.json"
cp "$TEST_CONFIG_DIR/settings.json" "$TEST_ROOT/settings.invalid"
set +e
output="$(CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR" /bin/bash "$TEST_REPO/install.sh" \
  --target claude --no-vendor 2>&1)"
status=$?
set -e

if [ "$status" -ne 1 ]; then
  printf '%s\n' "$output" >&2
  printf 'FAIL: invalid local settings exited with %s; expected 1\n' "$status" >&2
  exit 1
fi
cmp -s "$TEST_ROOT/settings.invalid" "$TEST_CONFIG_DIR/settings.json"
case "$output" in
  *"不是有效的 JSON 对象，已跳过"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: invalid local settings were not diagnosed\n' >&2
    exit 1
    ;;
esac

printf 'PASS: Claude settings are merged as a repository overlay\n'

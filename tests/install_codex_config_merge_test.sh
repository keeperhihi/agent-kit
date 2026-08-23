#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_ROOT="$(mktemp -d "${TEST_TMP_ROOT%/}/agent-kit-codex-test.XXXXXX")"
TEST_REPO="$TEST_ROOT/repo"
TEST_HOME="$TEST_ROOT/home"
CODEX_DIR="$TEST_HOME/.codex"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_REPO/codex" "$TEST_REPO/skills/example" "$CODEX_DIR"
cp "$REPO/install.sh" "$TEST_REPO/install.sh"
printf '%s\n' '# Test instructions' > "$TEST_REPO/codex/AGENTS.md"

cat > "$TEST_REPO/codex/config.toml.tmpl" <<'TOML'
# repository overlay
model = "repo"
model_verbosity = "medium"
items = ["repo-item"]

[provider]
base_url = "repo"
repo_only = true

[tui]
status_line = ["repo"]

[notice]
enabled = true
TOML

cat > "$CODEX_DIR/config.toml" <<'TOML'
# local comment must survive
model = "local"
model_verbosity = "high"
local_only = true
items = ["local-item"]

[provider]
base_url = "local"
provider_only = "keep"

[tui.model_availability_nux]
"local" = 1

[local_table]
value = 7
TOML

output="$(HOME="$TEST_HOME" /bin/bash "$TEST_REPO/install.sh" --target codex --no-vendor 2>&1)"
case "$output" in
  *"config.toml 已合并仓库设置"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: initial Codex config merge was not reported\n' >&2
    exit 1
    ;;
esac

grep -F 'model = "repo"' "$CODEX_DIR/config.toml" >/dev/null
grep -F 'model_verbosity = "medium"' "$CODEX_DIR/config.toml" >/dev/null
grep -F 'items = ["repo-item"]' "$CODEX_DIR/config.toml" >/dev/null
grep -F '# local comment must survive' "$CODEX_DIR/config.toml" >/dev/null
grep -F 'local_only = true' "$CODEX_DIR/config.toml" >/dev/null
grep -F 'provider_only = "keep"' "$CODEX_DIR/config.toml" >/dev/null
grep -F 'repo_only = true' "$CODEX_DIR/config.toml" >/dev/null
grep -F 'value = 7' "$CODEX_DIR/config.toml" >/dev/null
grep -F 'status_line = ["repo"]' "$CODEX_DIR/config.toml" >/dev/null
grep -F 'enabled = true' "$CODEX_DIR/config.toml" >/dev/null

# A parent table must be inserted before an existing child table, not appended
# after it (which would redefine the TOML table).
parent_line="$(grep -n '^\[tui\]$' "$CODEX_DIR/config.toml" | cut -d: -f1)"
child_line="$(grep -n '^\[tui\.model_availability_nux\]$' "$CODEX_DIR/config.toml" | cut -d: -f1)"
[ -n "$parent_line" ] && [ -n "$child_line" ] && [ "$parent_line" -lt "$child_line" ]

cp "$CODEX_DIR/config.toml" "$TEST_ROOT/config.after-first"
output="$(HOME="$TEST_HOME" /bin/bash "$TEST_REPO/install.sh" --target codex --no-vendor 2>&1)"
cmp -s "$TEST_ROOT/config.after-first" "$CODEX_DIR/config.toml"
case "$output" in
  *"config.toml 的仓库设置已生效"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: repeated install did not report an up-to-date Codex overlay\n' >&2
    exit 1
    ;;
esac

output="$(HOME="$TEST_HOME" /bin/bash "$TEST_REPO/install.sh" --target codex --status 2>&1)"
case "$output" in
  *"config.toml 的仓库设置已生效"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: Codex status did not accept local-only config entries\n' >&2
    exit 1
    ;;
esac

# Changing an overlay key should be visible in dry-run but must not write.
sed 's/model = "repo"/model = "repo-v2"/' "$TEST_REPO/codex/config.toml.tmpl" > "$TEST_ROOT/template.next"
mv "$TEST_ROOT/template.next" "$TEST_REPO/codex/config.toml.tmpl"
cp "$CODEX_DIR/config.toml" "$TEST_ROOT/config.before-dry-run"
output="$(HOME="$TEST_HOME" /bin/bash "$TEST_REPO/install.sh" --target codex --no-vendor --dry-run 2>&1)"
cmp -s "$TEST_ROOT/config.before-dry-run" "$CODEX_DIR/config.toml"
[ ! -e "$CODEX_DIR/.agent-kit-backups" ]
case "$output" in
  *"config.toml 将合并仓库设置"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: Codex dry-run did not report the pending merge\n' >&2
    exit 1
    ;;
esac

HOME="$TEST_HOME" /bin/bash "$TEST_REPO/install.sh" --target codex --no-vendor --force >/dev/null
backup_count="$(find "$CODEX_DIR/.agent-kit-backups" -type f -path '*/config.toml' | wc -l | tr -d ' ')"
[ "$backup_count" -eq 1 ]
legacy_backup_count="$(find "$CODEX_DIR" -maxdepth 1 -type f -name 'config.toml.bak.*' | wc -l | tr -d ' ')"
[ "$legacy_backup_count" -eq 0 ]
backup_file="$(find "$CODEX_DIR/.agent-kit-backups" -type f -path '*/config.toml' | head -1)"
grep -F 'model = "repo"' "$backup_file" >/dev/null
grep -F 'model = "repo-v2"' "$CODEX_DIR/config.toml" >/dev/null
grep -F 'local_only = true' "$CODEX_DIR/config.toml" >/dev/null

# An unsupported overlay line must leave the local config untouched.
printf '%s\n' 'not valid TOML' > "$TEST_REPO/codex/config.toml.tmpl"
cp "$CODEX_DIR/config.toml" "$TEST_ROOT/config.before-invalid"
set +e
output="$(HOME="$TEST_HOME" /bin/bash "$TEST_REPO/install.sh" --target codex --no-vendor 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ]
cmp -s "$TEST_ROOT/config.before-invalid" "$CODEX_DIR/config.toml"
case "$output" in
  *"config.toml: 合并失败，原文件未改动"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: invalid Codex overlay was not diagnosed\n' >&2
    exit 1
    ;;
esac

printf 'PASS: Codex config.toml is merged as a repository overlay\n'

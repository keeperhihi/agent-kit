#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_ROOT="$(mktemp -d "${TEST_TMP_ROOT%/}/agent-kit-backup-layout-test.XXXXXX")"
TEST_REPO="$TEST_ROOT/repo"
TEST_HOME="$TEST_ROOT/home"
CODEX_DIR="$TEST_HOME/.codex"
BACKUP_ROOT="$CODEX_DIR/.agent-kit-backups"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_REPO/codex" "$TEST_REPO/skills/example" "$CODEX_DIR/skills/example"
cp "$REPO/install.sh" "$TEST_REPO/install.sh"
printf '%s\n' '# Test instructions' > "$TEST_REPO/codex/AGENTS.md"
printf '%s\n' '# New skill' > "$TEST_REPO/skills/example/SKILL.md"
printf '%s\n' 'old skill content' > "$CODEX_DIR/skills/example/old.txt"

cat > "$TEST_REPO/codex/config.toml.tmpl" <<'TOML'
model = "repo"
TOML

cat > "$CODEX_DIR/config.toml" <<'TOML'
model = "local"
TOML

output="$(HOME="$TEST_HOME" \
  /bin/bash "$TEST_REPO/install.sh" --target codex --no-vendor --force 2>&1)"

[ -L "$CODEX_DIR/skills/example" ]
[ "$(readlink "$CODEX_DIR/skills/example")" = "$TEST_REPO/skills/example" ]

run_count="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "$run_count" -eq 1 ]

skill_backup="$(find "$BACKUP_ROOT" -type f -path '*/skills/example/old.txt' | head -1)"
config_backup="$(find "$BACKUP_ROOT" -type f -path '*/config.toml' | head -1)"
[ -n "$skill_backup" ] && [ -f "$skill_backup" ]
[ -n "$config_backup" ] && [ -f "$config_backup" ]
grep -F 'old skill content' "$skill_backup" >/dev/null
grep -F 'model = "local"' "$config_backup" >/dev/null

legacy_count="$(find "$CODEX_DIR" -maxdepth 2 -name '*.bak.*' | wc -l | tr -d ' ')"
[ "$legacy_count" -eq 0 ]
[ ! -e "$TEST_HOME/.agent-kit-backups" ]

case "$output" in
  *"已备份到 $BACKUP_ROOT/"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: backup destination was not reported under the central root\n' >&2
    exit 1
    ;;
esac

printf 'PASS: --force stores link and config backups in one run directory\n'

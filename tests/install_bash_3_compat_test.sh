#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_CONFIG_DIR="$(mktemp -d "${TEST_TMP_ROOT%/}/agent-kit-install-test.XXXXXX")"

cleanup() {
  rm -f "$TEST_CONFIG_DIR/settings.json"
  rmdir "$TEST_CONFIG_DIR"
}
trap cleanup EXIT

set +e
output="$(CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR" /bin/bash "$REPO/install.sh" \
  --target claude --dry-run 2>&1)"
status=$?
set -e

if [ "$status" -ne 0 ]; then
  printf '%s\n' "$output" >&2
  printf 'FAIL: install.sh exited with %s under /bin/bash\n' "$status" >&2
  exit 1
fi

case "$output" in
  *"+ plugin claude-hud config.json"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: Claude plugin files were not traversed\n' >&2
    exit 1
    ;;
esac

set +e
output="$(CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR" /bin/bash "$REPO/install.sh" \
  --target claude --status 2>&1)"
status=$?
set -e

if [ "$status" -ne 1 ]; then
  printf '%s\n' "$output" >&2
  printf 'FAIL: install.sh --status exited with %s under /bin/bash; expected 1 for an empty config\n' "$status" >&2
  exit 1
fi

case "$output" in
  *"plugin claude-hud config.json 未安装"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: Claude plugin status files were not traversed\n' >&2
    exit 1
    ;;
esac

# 已有设置会触发同步提示；Bash 3.2 在 C.UTF-8 下需要明确变量与中文的边界。
printf '%s\n' '{}' > "$TEST_CONFIG_DIR/settings.json"
set +e
output="$(LC_ALL=C.UTF-8 CLAUDE_CONFIG_DIR="$TEST_CONFIG_DIR" /bin/bash "$REPO/install.sh" \
  --target claude --dry-run 2>&1)"
status=$?
set -e

if [ "$status" -ne 0 ]; then
  printf '%s\n' "$output" >&2
  printf 'FAIL: settings sync report failed under /bin/bash with LC_ALL=C.UTF-8\n' >&2
  exit 1
fi

case "$output" in
  *"settings.json 将合并仓库设置"*) ;;
  *)
    printf '%s\n' "$output" >&2
    printf 'FAIL: settings sync report was not printed\n' >&2
    exit 1
    ;;
esac

printf 'PASS: Claude install and status checks work under /bin/bash\n'

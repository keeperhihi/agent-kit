#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_ROOT="$(mktemp -d "${TEST_TMP_ROOT%/}/agent-kit-skills-test.XXXXXX")"
TEST_REPO="$TEST_ROOT/repo"
TEST_HOME="$TEST_ROOT/home"
trap 'rm -rf "$TEST_ROOT"' EXIT

[ ! -L "$REPO/codex/AGENTS.md" ]
[ "$(readlink "$REPO/claude/CLAUDE.md")" = '../codex/AGENTS.md' ]

mkdir -p "$TEST_REPO/codex" "$TEST_REPO/claude" "$TEST_REPO/skills/example" "$TEST_REPO/vendor/skills/firecrawl"
cp "$REPO/install.sh" "$TEST_REPO/install.sh"
printf '%s\n' '# Shared instructions' > "$TEST_REPO/codex/AGENTS.md"
ln -s ../codex/AGENTS.md "$TEST_REPO/claude/CLAUDE.md"
printf '%s\n' 'model = "repo"' > "$TEST_REPO/codex/config.toml.tmpl"
printf '%s\n' '{}' > "$TEST_REPO/claude/settings.json"
printf '%s\n' '# Example skill' > "$TEST_REPO/skills/example/SKILL.md"
printf '%s\n' '# Optional third-party skill' > "$TEST_REPO/vendor/skills/firecrawl/SKILL.md"

for target in .claude .codex; do
  mkdir -p "$TEST_HOME/$target/skills/local"
  ln -s "$TEST_ROOT/other/missing-skill" "$TEST_HOME/$target/skills/external"
  printf '%s\n' 'local skill' > "$TEST_HOME/$target/skills/local/SKILL.md"
done

HOME="$TEST_HOME" CLAUDE_CONFIG_DIR="$TEST_HOME/.claude" \
  /bin/bash "$TEST_REPO/install.sh" --target both >/dev/null
for target in .claude .codex; do
  [ ! -e "$TEST_HOME/$target/skills/firecrawl" ]
  [ ! -L "$TEST_HOME/$target/skills/firecrawl" ]
  [ -L "$TEST_HOME/$target/skills/external" ]
  [ -f "$TEST_HOME/$target/skills/local/SKILL.md" ]
  [ -L "$TEST_HOME/$target/skills/example" ]
done
cmp -s "$TEST_REPO/codex/AGENTS.md" "$TEST_HOME/.codex/AGENTS.md"
cmp -s "$TEST_REPO/codex/AGENTS.md" "$TEST_HOME/.claude/CLAUDE.md"

HOME="$TEST_HOME" CLAUDE_CONFIG_DIR="$TEST_HOME/.claude" \
  /bin/bash "$TEST_REPO/install.sh" --target both --with-vendor --dry-run >/dev/null
for target in .claude .codex; do
  [ ! -L "$TEST_HOME/$target/skills/firecrawl" ]
done

HOME="$TEST_HOME" CLAUDE_CONFIG_DIR="$TEST_HOME/.claude" \
  /bin/bash "$TEST_REPO/install.sh" --target both --with-vendor >/dev/null
for target in .claude .codex; do
  [ "$(readlink "$TEST_HOME/$target/skills/firecrawl")" = "$TEST_REPO/vendor/skills/firecrawl" ]
done

# A later default install must not uninstall skills explicitly selected earlier.
HOME="$TEST_HOME" CLAUDE_CONFIG_DIR="$TEST_HOME/.claude" \
  /bin/bash "$TEST_REPO/install.sh" --target both >/dev/null
for target in .claude .codex; do
  [ -L "$TEST_HOME/$target/skills/firecrawl" ]
  [ -L "$TEST_HOME/$target/skills/external" ]
  [ -f "$TEST_HOME/$target/skills/local/SKILL.md" ]
done

printf 'PASS: shared instructions install and third-party skills require --with-vendor\n'

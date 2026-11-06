#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-kit-config-test.XXXXXX")"
TEST_REPO="$TEST_ROOT/repo with spaces"
CODEX_DIR="$TEST_ROOT/custom codex"
CLAUDE_DIR="$TEST_ROOT/custom claude"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_REPO/codex" "$TEST_REPO/claude" "$TEST_REPO/skills/example"
cp "$REPO/install.sh" "$TEST_REPO/install.sh"
cp "$REPO/codex/config.toml.tmpl" "$TEST_REPO/codex/config.toml.tmpl"
printf '%s\n' '# Instructions' > "$TEST_REPO/codex/AGENTS.md"
ln -s ../codex/AGENTS.md "$TEST_REPO/claude/CLAUDE.md"
printf '%s\n' '{"theme":"dark"}' > "$TEST_REPO/claude/settings.json"
printf '%s\n' '# Skill' > "$TEST_REPO/skills/example/SKILL.md"

run_install() {
  CODEX_HOME="$CODEX_DIR/" CLAUDE_CONFIG_DIR="$CLAUDE_DIR" \
    "$BASH" "$TEST_REPO/install.sh" "$@"
}

# Dry-run must neither create a configuration directory nor reveal the key.
output="$(run_install --cm-key test-secret-dry --dry-run)"
[ ! -e "$CODEX_DIR" ]
[ ! -e "$CLAUDE_DIR" ]
case "$output" in *test-secret-dry*) exit 1 ;; esac

# A fresh, argument-free install targets Codex and creates an empty credential.
run_install >/dev/null
cmp "$TEST_REPO/codex/config.toml.tmpl" "$CODEX_DIR/config.toml"
[ ! -e "$CLAUDE_DIR" ]
[ ! -e "$CODEX_DIR/.agent-kit-backups" ]
jq -e '. == {auth_mode: "apikey", OPENAI_API_KEY: ""}' "$CODEX_DIR/auth.json" >/dev/null
run_install --status >/dev/null
rm "$CODEX_DIR/skills/example"
if run_install --status >/dev/null; then exit 1; fi
ln -s "$TEST_REPO/skills/example" "$CODEX_DIR/skills/example"

# Existing local settings, auth, and matching skills are replaced together.
cat > "$CODEX_DIR/config.toml" <<'TOML'
model_provider = "old-provider"
model = "local-model"
[projects."/local/project"]
trust_level = "trusted"
[mcp_servers.local]
command = "/local/tool"
args = [
  "--local",
]
TOML
printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"old-test-token"}}' > "$CODEX_DIR/auth.json"
cp "$CODEX_DIR/config.toml" "$TEST_ROOT/original-config"
cp "$CODEX_DIR/auth.json" "$TEST_ROOT/original-auth"
mkdir -p "$CODEX_DIR/sessions" "$CODEX_DIR/skills/user-only"
printf '%s\n' 'session data' > "$CODEX_DIR/sessions/keep.jsonl"
printf '%s\n' 'database data' > "$CODEX_DIR/state.sqlite"
printf '%s\n' '# User skill' > "$CODEX_DIR/skills/user-only/SKILL.md"
rm "$CODEX_DIR/skills/example"
mkdir "$CODEX_DIR/skills/example"
printf '%s\n' '# Old skill' > "$CODEX_DIR/skills/example/SKILL.md"

if run_install --status >/dev/null; then exit 1; fi
run_install --dry-run >/dev/null
cmp "$TEST_ROOT/original-config" "$CODEX_DIR/config.toml"
cmp "$TEST_ROOT/original-auth" "$CODEX_DIR/auth.json"
[ ! -e "$CODEX_DIR/.agent-kit-backups" ]

TEST_KEY=$'test-"key"\\path\tline\nnext\r\001中文'
output="$(run_install --cm-key "$TEST_KEY")"
case "$output" in *'test-"key"'*) exit 1 ;; esac
cmp "$TEST_REPO/codex/config.toml.tmpl" "$CODEX_DIR/config.toml"
jq -e --arg key "$TEST_KEY" '. == {auth_mode: "apikey", OPENAI_API_KEY: $key}' "$CODEX_DIR/auth.json" >/dev/null
set -- "$CODEX_DIR"/.agent-kit-backups/*
[ "$#" -eq 1 ]
BACKUP="$1"
cmp "$TEST_ROOT/original-config" "$BACKUP/config.toml"
cmp "$TEST_ROOT/original-auth" "$BACKUP/auth.json"
[ -f "$BACKUP/skills/example/SKILL.md" ]
[ -L "$CODEX_DIR/skills/example" ]
[ "$(cat "$CODEX_DIR/sessions/keep.jsonl")" = 'session data' ]
[ "$(cat "$CODEX_DIR/state.sqlite")" = 'database data' ]
[ "$(cat "$CODEX_DIR/skills/user-only/SKILL.md")" = '# User skill' ]
[ "$(ls -ld "$BACKUP" | cut -c1-10)" = 'drwx------' ]
[ "$(ls -l "$CODEX_DIR/auth.json" | cut -c1-10)" = '-rw-------' ]

# Omitting --cm-key on reinstall clears the new credential, after backing it up.
run_install >/dev/null
jq -e '.OPENAI_API_KEY == ""' "$CODEX_DIR/auth.json" >/dev/null
set -- "$CODEX_DIR"/.agent-kit-backups/*
[ "$#" -eq 2 ]

# Relative links must be replaced without modifying the external source.
mkdir "$TEST_ROOT/external"
printf '%s\n' 'external config' > "$TEST_ROOT/external/config"
rm "$CODEX_DIR/config.toml"
ln -s '../external/config' "$CODEX_DIR/config.toml"
run_install >/dev/null
[ ! -L "$CODEX_DIR/config.toml" ]
[ "$(cat "$TEST_ROOT/external/config")" = 'external config' ]
found=0
for file in "$CODEX_DIR"/.agent-kit-backups/*/config.toml; do
  if cmp -s "$TEST_ROOT/external/config" "$file"; then found=1; fi
done
[ "$found" -eq 1 ]

# An unwritable backup destination must stop before touching config or auth.
FAIL_DIR="$TEST_ROOT/blocked codex"
mkdir "$FAIL_DIR"
cp "$TEST_ROOT/original-config" "$FAIL_DIR/config.toml"
cp "$TEST_ROOT/original-auth" "$FAIL_DIR/auth.json"
touch "$FAIL_DIR/.agent-kit-backups"
if CODEX_HOME="$FAIL_DIR" "$BASH" "$TEST_REPO/install.sh" >/dev/null 2>&1; then exit 1; fi
cmp "$TEST_ROOT/original-config" "$FAIL_DIR/config.toml"
cmp "$TEST_ROOT/original-auth" "$FAIL_DIR/auth.json"

# Claude follows the same replacement contract, including invalid local JSON.
mkdir -p "$CLAUDE_DIR"
printf '%s\n' '{invalid local settings' > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$TEST_ROOT/original-settings"
run_install --target claude >/dev/null
cmp "$TEST_REPO/claude/settings.json" "$CLAUDE_DIR/settings.json"
set -- "$CLAUDE_DIR"/.agent-kit-backups/*/settings.json
cmp "$TEST_ROOT/original-settings" "$1"

for option in --force --pull --cm-key; do
  if run_install "$option" >/dev/null 2>&1; then exit 1; fi
done
if run_install --target claude --cm-key unused >/dev/null 2>&1; then exit 1; fi

run_install --target both --uninstall >/dev/null
[ ! -L "$CODEX_DIR/AGENTS.md" ]
[ ! -L "$CLAUDE_DIR/CLAUDE.md" ]
[ -f "$CODEX_DIR/auth.json" ]
[ -f "$CODEX_DIR/config.toml" ]
[ -f "$CODEX_DIR/skills/user-only/SKILL.md" ]

printf 'PASS: default replacement, backups, auth, custom paths, dry-run, and uninstall\n'

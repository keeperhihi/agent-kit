#!/usr/bin/env bash
# 安装仓库配置：已有目标先备份，再替换。默认安装 Codex。
# 配置和凭证使用普通文件；指令、skills 和 Claude 插件配置使用符号链接。
set -euo pipefail
umask 077

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_DIR="${CLAUDE_DIR%/}"
CODEX_DIR="${CODEX_DIR%/}"
CLAUDE_BACKUP_ROOT="$CLAUDE_DIR/.agent-kit-backups"
CODEX_BACKUP_ROOT="$CODEX_DIR/.agent-kit-backups"

TARGET=codex
MODE=install
DRY=0
CM_KEY=""
CM_KEY_SET=0
VENDOR=0
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_SESSION="$STAMP-$$"
rc=0

usage() {
  cat <<'EOF'
用法: ./install.sh [选项]

  --target claude|codex|both   安装目标（默认 codex）
  --with-vendor                同时安装 vendor/skills 中的第三方 skill（默认跳过）
  --dry-run                    只打印将要做什么
  --cm-key KEY                 将 CodexManager key 写入 auth.json；省略时写入空字符串
  --status                     只检查安装状态，不改动任何东西
  --uninstall                  移除本仓库装出去的符号链接（不动普通文件）
  -h, --help                   显示本帮助

安装时自动备份并替换已有目标；备份位于对应配置目录的 .agent-kit-backups/<run-id>/。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      if [ $# -lt 2 ]; then echo "--target 需要参数" >&2; exit 2; fi
      TARGET="$2"; shift 2 ;;
    --with-vendor) VENDOR=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --cm-key)
      if [ $# -lt 2 ]; then echo "--cm-key 需要参数" >&2; exit 2; fi
      CM_KEY="$2"; CM_KEY_SET=1; shift 2 ;;
    --status) MODE=status; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知选项: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$TARGET" in claude|codex|both) ;; *) echo "--target 只能是 claude / codex / both" >&2; exit 2 ;; esac

if [ "$CM_KEY_SET" = 1 ] && { [ "$TARGET" = claude ] || [ "$MODE" != install ]; }; then
  echo "--cm-key 仅用于安装 Codex（--target codex 或 both）" >&2
  exit 2
fi

say()  { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; rc=1; }
run()  {
  if [ "$DRY" = 1 ]; then
    printf '  [dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

backup_path() { # backup_path <目标路径>
  local dst="$1" root rel
  case "$dst" in
    "$CLAUDE_DIR"/*)
      root="$CLAUDE_BACKUP_ROOT"
      rel="${dst#"$CLAUDE_DIR"/}"
      ;;
    "$CODEX_DIR"/*)
      root="$CODEX_BACKUP_ROOT"
      rel="${dst#"$CODEX_DIR"/}"
      ;;
    *)
      root="$CLAUDE_BACKUP_ROOT"
      rel="other/$(basename "$dst")"
      ;;
  esac
  printf '%s/%s/%s\n' "$root" "$BACKUP_SESSION" "$rel"
}

backup_target() { # backup_target <源路径> <显示名>
  local src="$1" name="$2" backup
  backup="$(backup_path "$src")"
  if [ "$DRY" = 0 ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
    warn "$name: 备份目标已存在，拒绝覆盖: $backup"
    return 1
  fi
  if ! run mkdir -p -- "$(dirname "$backup")"; then
    warn "$name: 无法创建备份目录: $(dirname "$backup")"
    return 1
  fi
  # 相对符号链接移动后可能失效，备份其内容并仅移除链接本身。
  if [ -L "$src" ] && [ -e "$src" ]; then
    if ! run cp -pRH -- "$src" "$backup" || ! run rm -- "$src"; then
      warn "$name: 无法备份到 $backup"
      return 1
    fi
  elif ! run mv -- "$src" "$backup"; then
    warn "$name: 无法备份到 $backup"
    return 1
  fi
  say "~ $name: 原文件已备份到 $backup"
}

# 使用 readlink 和 cd -P，兼容没有 readlink -f 的 macOS。
resolve_path() (
  local path="$1" dir target
  while :; do
    dir="$(cd -P -- "$(dirname "$path")" && pwd)" || return 1
    path="$dir/$(basename "$path")"
    [ -L "$path" ] || break
    target="$(readlink "$path")" || return 1
    case "$target" in /*) path="$target" ;; *) path="$dir/$target" ;; esac
  done
  printf '%s\n' "$path"
)

owned_by_repo() {
  [ -L "$1" ] && case "$(resolve_path "$1" 2>/dev/null || true)" in "$REPO"/*) return 0 ;; esac
  return 1
}
owned_plugin_file() {
  local target repo_root rest plugin file
  [ -L "$1" ] || return 1
  target="$(resolve_path "$1" 2>/dev/null || true)"
  repo_root="$REPO"
  [ -n "$repo_root" ] || return 1
  case "$target" in "$repo_root"/claude/plugins/*) ;; *) return 1 ;; esac
  target="${target#"$repo_root"/claude/plugins/}"
  rest="$target"
  plugin="${rest%%/*}"
  [ -n "$plugin" ] && [ "$plugin" != "$rest" ] || return 1
  rest="${rest#*/}"
  case "$rest" in files/*) ;; *) return 1 ;; esac
  file="${rest#files/}"
  [ -n "$file" ] || return 1
  case "/$plugin/$file/" in *"//"*|*/./*|*/../*) return 1 ;; esac
  return 0
}
linked_to() { [ -L "$2" ] && [ "$(resolve_path "$2" 2>/dev/null || true)" = "$(resolve_path "$1" 2>/dev/null || true)" ]; }

link() { # link <仓库内源> <目标路径> <显示名>
  local src="$1" dst="$2" name="$3"
  if [ ! -e "$src" ]; then warn "$name: 源不存在 $src"; return; fi
  if linked_to "$src" "$dst"; then
    say "= $name (已链接)"; return
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    backup_target "$dst" "$name" || return
  fi
  run mkdir -p -- "$(dirname "$dst")"
  run ln -s -- "$src" "$dst"
  say "+ $name"
}

install_file() { # install_file <仓库内源> <目标路径> <显示名>
  local src="$1" dst="$2" name="$3"
  if [ ! -f "$src" ]; then warn "$name: 源不存在 $src"; return; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    backup_target "$dst" "$name" || return
  fi
  run mkdir -p -- "$(dirname "$dst")"
  run cp -- "$src" "$dst"
  say "+ $name: 已安装仓库配置"
}

json_string() { # 输出一个 JSON 字符串；不依赖 jq/Python，不展开 key 中的转义。
  local value="$1" i c LC_ALL=C
  printf '"'
  for ((i=0; i<${#value}; i++)); do
    c="${value:i:1}"
    case "$c" in
      '"'|'\') printf '\\%s' "$c" ;;
      [[:cntrl:]]) printf '\\u%04x' "'$c" ;;
      *) printf '%s' "$c" ;;
    esac
  done
  printf '"'
}

install_auth() {
  local dst="$CODEX_DIR/auth.json"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    backup_target "$dst" auth.json || return
  fi
  run mkdir -p -- "$CODEX_DIR"
  if [ "$DRY" = 0 ]; then
    { printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": '; json_string "$CM_KEY"; printf '\n}\n'; } > "$dst"
  fi
  say "+ auth.json（API key $([ -n "$CM_KEY" ] && printf 已设置 || printf 留空)）"
  if [ -z "$CM_KEY" ]; then say "请在 $dst 中填写 CodexManager 网关 key 后再使用 Codex。"; fi
}

status_file() { # status_file <仓库内源> <目标路径> <显示名>
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    say "= $3 与仓库一致"
  else
    warn "$3 缺失或与仓库不同；install 将备份并替换"
  fi
}

status_link() { # status_link <仓库内源> <目标路径> <显示名>
  if linked_to "$1" "$2"; then
    say "= $3 → 仓库"
  elif [ -e "$2" ] || [ -L "$2" ]; then
    warn "$3 存在但不指向仓库对应条目"
  else
    warn "$3 未安装"
  fi
}

link_skills() { # link_skills <目标 skills 目录>
  local into="$1" d n
  for d in "$REPO"/skills/*/; do [ -d "$d" ] || continue; n="$(basename "$d")"; link "${d%/}" "$into/$n" "skill $n"; done
  if [ "$VENDOR" = 1 ]; then
    for d in "$REPO"/vendor/skills/*/; do [ -d "$d" ] || continue; n="$(basename "$d")"; link "${d%/}" "$into/$n" "vendor skill $n"; done
  fi
}

link_dir_files() { # link_dir_files <仓库子目录> <目标目录> <标签>
  local from="$1" into="$2" label="$3" f n
  for f in "$from"/*.md; do [ -e "$f" ] || continue; n="$(basename "$f")"; link "$f" "$into/$n" "$label $n"; done
}

managed_repo_file() { # managed_repo_file <仓库内文件>
  local f="$1" repo_rel check_rc
  repo_rel="${f#"$REPO"/}"
  if git -C "$REPO" check-ignore --no-index -q -- "$repo_rel" 2>/dev/null; then
    return 1
  else
    check_rc=$?
  fi
  [ "$check_rc" = 1 ] && return 0
  warn "无法检查插件文件的忽略规则，已跳过: $repo_rel"
  return 1
}

link_tree_files() { # link_tree_files <仓库文件树> <目标目录> <标签>
  local from="$1" into="$2" label="$3" f rel
  [ -d "$from" ] || return 0
  while IFS= read -r -d '' f; do
    managed_repo_file "$f" || continue
    rel="${f#"$from"/}"
    link "$f" "$into/$rel" "$label $rel"
  done < <(find "$from" -type f -print0)
}

install_plugin_files() {
  local d name
  [ -d "$REPO/claude/plugins" ] || return 0
  for d in "$REPO"/claude/plugins/*/; do
    d="${d%/}"
    [ -d "$d/files" ] || continue
    name="$(basename "$d")"
    link_tree_files "$d/files" "$CLAUDE_DIR/plugins/$name" "plugin $name"
  done
}

status_plugin_files() {
  local d name f rel dst
  [ -d "$REPO/claude/plugins" ] || return 0
  for d in "$REPO"/claude/plugins/*/; do
    d="${d%/}"
    [ -d "$d/files" ] || continue
    name="$(basename "$d")"
    while IFS= read -r -d '' f; do
      managed_repo_file "$f" || continue
      rel="${f#"$d/files/"}"
      dst="$CLAUDE_DIR/plugins/$name/$rel"
      status_link "$f" "$dst" "plugin $name $rel"
    done < <(find "$d/files" -type f -print0)
  done
}

uninstall_plugin_files() {
  local root="$CLAUDE_DIR/plugins" p rel dir
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' p; do
    owned_plugin_file "$p" || continue
    rel="${p#"$root"/}"
    run rm -- "$p"
    say "- plugin $rel"
    if [ "$DRY" = 0 ]; then
      dir="$(dirname "$p")"
      while [ "$dir" != "$root" ]; do
        rmdir "$dir" 2>/dev/null || break
        dir="$(dirname "$dir")"
      done
    fi
  done < <(find "$root" \
    -type d \( -name cache -o -name marketplaces -o -name config-cache -o -name context-cache -o -name transcript-cache \) -prune -o \
    -type l -print0)
}

install_claude() {
  echo "→ $CLAUDE_DIR"
  link "$REPO/claude/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md" "CLAUDE.md"
  install_file "$REPO/claude/settings.json" "$CLAUDE_DIR/settings.json" settings.json
  link_skills "$CLAUDE_DIR/skills"
  link_dir_files "$REPO/claude/agents"   "$CLAUDE_DIR/agents"   "agent"
  link_dir_files "$REPO/claude/commands" "$CLAUDE_DIR/commands" "command"
  install_plugin_files
}

install_codex() {
  echo "→ $CODEX_DIR"
  link "$REPO/codex/AGENTS.md" "$CODEX_DIR/AGENTS.md" "AGENTS.md"
  link_skills "$CODEX_DIR/skills"
  install_file "$REPO/codex/config.toml.tmpl" "$CODEX_DIR/config.toml" config.toml
  install_auth
}

uninstall_from() { # uninstall_from <配置目录>
  local base="$1" p n
  echo "→ $base"
  for p in "$base/CLAUDE.md" "$base/AGENTS.md"; do
    owned_by_repo "$p" && { run rm -- "$p"; say "- $(basename "$p")"; }
  done
  for n in skills agents commands; do
    [ -d "$base/$n" ] || continue
    for p in "$base/$n"/*; do
      [ -e "$p" ] || [ -L "$p" ] || continue
      owned_by_repo "$p" && { run rm -- "$p"; say "- $n/$(basename "$p")"; }
    done
    [ "$DRY" = 1 ] || rmdir "$base/$n" 2>/dev/null || true
  done
  [ -f "$base/settings.json" ] && say "= settings.json 是本机普通文件，保留未动"
  [ -f "$base/config.toml" ] && say "= config.toml 是本机普通文件，保留未动"
  return 0
}

status_of() { # status_of <配置目录> <指令文件名>
  local base="$1" doc="$2" p n
  echo "→ $base"
  status_link "$REPO/codex/AGENTS.md" "$base/$doc" "$doc"
  for p in "$REPO"/skills/*/; do
    [ -d "$p" ] || continue
    n="$(basename "$p")"
    status_link "${p%/}" "$base/skills/$n" "skill $n"
  done
  if [ "$VENDOR" = 1 ]; then
    for p in "$REPO"/vendor/skills/*/; do
      [ -d "$p" ] || continue
      n="$(basename "$p")"
      status_link "${p%/}" "$base/skills/$n" "vendor skill $n"
    done
  fi
  if [ "$doc" = CLAUDE.md ]; then
    for n in agents commands; do
      for p in "$REPO/claude/$n"/*.md; do
        [ -f "$p" ] || continue
        status_link "$p" "$base/$n/$(basename "$p")" "$n/$(basename "$p")"
      done
    done
  fi
  return 0
}

echo "仓库: $REPO"
want_claude() { [ "$TARGET" = claude ] || [ "$TARGET" = both ]; }
want_codex()  { [ "$TARGET" = codex ]  || [ "$TARGET" = both ]; }

case "$MODE" in
  install)
    if want_claude; then install_claude; fi
    if want_codex;  then install_codex;  fi
    ;;
  uninstall)
    if want_claude; then uninstall_from "$CLAUDE_DIR"; uninstall_plugin_files; fi
    if want_codex;  then uninstall_from "$CODEX_DIR";  fi
    ;;
  status)
    if want_claude; then status_of "$CLAUDE_DIR" CLAUDE.md; status_file "$REPO/claude/settings.json" "$CLAUDE_DIR/settings.json" settings.json; status_plugin_files; fi
    if want_codex; then
      status_of "$CODEX_DIR" AGENTS.md
      status_file "$REPO/codex/config.toml.tmpl" "$CODEX_DIR/config.toml" config.toml
      if [ -f "$CODEX_DIR/auth.json" ]; then say "= auth.json 存在（未验证凭证）"; else warn "auth.json 未安装"; fi
    fi
    ;;
esac

[ "$rc" = 0 ] && echo "完成。" || echo "完成，但有上面标 ! 的项需要你确认。"
exit "$rc"

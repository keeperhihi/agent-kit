#!/usr/bin/env bash
# 把本仓库安装到 ~/.claude（默认）和/或 ~/.codex。
# settings.json 和 Codex config.toml 作为 overlay 合并；其他受管文件使用符号链接。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="$HOME/.codex"

TARGET=claude
MODE=install
DRY=0
FORCE=0
VENDOR=1
STAMP="$(date +%Y%m%d%H%M%S)"
rc=0

usage() {
  cat <<'EOF'
用法: ./install.sh [选项]

  --target claude|codex|both   安装目标（默认 claude）
  --no-vendor                  跳过 vendor/skills（第三方 skill）
  --dry-run                    只打印将要做什么
  --force                      覆盖已有目标前备份；settings/config 合并前也创建备份
  --status                     只检查安装状态，不改动任何东西
  --uninstall                  移除本仓库装出去的符号链接（不动普通文件）
  -h, --help                   显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?--target 需要参数}"; shift 2 ;;
    --no-vendor) VENDOR=0; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --status) MODE=status; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知选项: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$TARGET" in claude|codex|both) ;; *) echo "--target 只能是 claude / codex / both" >&2; exit 2 ;; esac

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

# 目标是不是本仓库装出去的链接。macOS 的 /var 与 /private/var 可能有两种
# realpath，源路径和目标路径都先规范化，避免 status 在临时目录下误报漂移。
owned_by_repo() {
  local repo_root
  repo_root="$(readlink -f "$REPO" || true)"
  [ -n "$repo_root" ] || return 1
  [ -L "$1" ] && case "$(readlink -f "$1" || true)" in "$repo_root"/*) return 0 ;; esac
  return 1
}
owned_plugin_file() {
  local target repo_root rest plugin file
  [ -L "$1" ] || return 1
  target="$(readlink -f "$1" || true)"
  repo_root="$(readlink -f "$REPO" || true)"
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
linked_to() { [ -L "$2" ] && [ "$(readlink -f "$2" || true)" = "$(readlink -f "$1" || true)" ]; }

link() { # link <仓库内源> <目标路径> <显示名>
  local src="$1" dst="$2" name="$3"
  if [ ! -e "$src" ]; then warn "$name: 源不存在 $src"; return; fi
  if linked_to "$src" "$dst"; then
    say "= $name (已链接)"; return
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ "$FORCE" = 1 ]; then
      run mv -- "$dst" "$dst.bak.$STAMP"; say "~ $name: 原文件已备份为 $(basename "$dst").bak.$STAMP"
    else
      warn "$name: $dst 已存在且不是本仓库的链接 —— 跳过（--force 可备份后覆盖）"; return
    fi
  fi
  run mkdir -p -- "$(dirname "$dst")"
  run ln -s -- "$src" "$dst"
  say "+ $name"
}

link_plugin_file() { # 内容一致的本机普通文件可安全接管为插件配置链接
  local src="$1" dst="$2" name="$3"
  if [ -f "$src" ] && [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst"; then
    run rm -- "$dst"
    run ln -s -- "$src" "$dst"
    say "~ $name: 内容一致，已接管为链接"
    return
  fi
  link "$src" "$dst" "$name"
}

require_jq() {
  if command -v jq >/dev/null 2>&1; then return 0; fi
  warn "settings.json 合并需要 jq，已跳过"
  return 1
}

json_object() { jq -e 'type == "object"' "$1" >/dev/null 2>&1; }

settings_overlay_applied() { # settings_overlay_applied <本机设置> <仓库 overlay>
  jq -e -s '(.[0] * .[1]) == .[0]' "$1" "$2" >/dev/null 2>&1
}

install_settings() { # install_settings <仓库 overlay> <本机设置>
  local src="$1" dst="$2" backup tmp
  if [ ! -f "$src" ]; then warn "settings.json: 源不存在 $src"; return; fi
  require_jq || return 0
  if ! json_object "$src"; then
    warn "settings.json: $src 不是有效的 JSON 对象，已跳过"
    return
  fi

  if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
    run mkdir -p -- "$(dirname "$dst")"
    run cp -- "$src" "$dst"
    say "+ settings.json"
    return
  fi
  if ! json_object "$dst"; then
    warn "settings.json: $dst 不是有效的 JSON 对象，已跳过"
    return
  fi
  if settings_overlay_applied "$dst" "$src"; then
    say "= settings.json 的仓库设置已生效"
    return
  fi

  if [ "$FORCE" = 1 ]; then
    backup="$dst.bak.$STAMP"
    if ! run cp -p -- "$dst" "$backup"; then
      warn "settings.json: 无法备份到 $backup，已跳过合并"
      return
    fi
    say "~ settings.json: 原文件已备份为 $(basename "$backup")"
  fi
  if [ "$DRY" = 1 ]; then
    say "~ settings.json 将合并仓库设置"
    return
  fi

  if ! tmp="$(mktemp "${dst}.tmp.XXXXXX")"; then
    warn "settings.json: 无法创建临时文件，已跳过合并"
    return
  fi
  if ! cp -p -- "$dst" "$tmp"; then
    rm -f -- "$tmp"
    warn "settings.json: 无法准备临时文件，已跳过合并"
    return
  fi
  if ! jq -s '.[0] * .[1]' "$dst" "$src" > "$tmp"; then
    rm -f -- "$tmp"
    warn "settings.json: 合并失败，原文件未改动"
    return
  fi
  if ! mv -- "$tmp" "$dst"; then
    rm -f -- "$tmp"
    warn "settings.json: 无法替换原文件"
    return
  fi
  say "~ settings.json 已合并仓库设置"
}

status_settings() { # status_settings <仓库 overlay> <本机设置>
  local src="$1" dst="$2"
  if [ ! -f "$src" ]; then warn "settings.json: 源不存在 $src"; return; fi
  require_jq || return 0
  if ! json_object "$src"; then
    warn "settings.json: $src 不是有效的 JSON 对象"
    return
  fi
  if [ ! -f "$dst" ]; then
    warn "settings.json 未安装"
    return
  fi
  if ! json_object "$dst"; then
    warn "settings.json: $dst 不是有效的 JSON 对象"
    return
  fi
  if settings_overlay_applied "$dst" "$src"; then
    say "= settings.json 的仓库设置已生效"
  else
    warn "settings.json 的仓库设置未完全生效 —— 运行 ./install.sh 合并"
  fi
}

# 只把模板中的赋值覆盖到本机 config.toml；本机独有的键、表和注释保留。
# 这样不需要额外安装 TOML 解析器，也不会把机器专属配置重新格式化一遍。
toml_overlay_merge() { # toml_overlay_merge <仓库 overlay> <本机 config.toml>
  local src="$1" dst="$2"
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function header(s, t) {
      t=trim(s)
      sub(/[[:space:]]+#.*$/, "", t)
      if (t ~ /^\[\[/ && t ~ /\]\]$/) return t
      if (t ~ /^\[/ && t ~ /\]$/) return t
      return ""
    }
    function key_of(s, p, k) {
      p=index(s, "=")
      if (!p) return ""
      k=trim(substr(s, 1, p-1))
      return k
    }
    function fail(msg) {
      print "TOML overlay error: " msg > "/dev/stderr"
      failed=1
    }
    function remember_section(sec) {
      if (!(sec in overlay_section_seen)) {
        overlay_section_seen[sec]=1
        overlay_sections[++overlay_section_count]=sec
      }
    }
    function remember_assignment(sec, line, key, id, n) {
      key=key_of(line)
      if (key == "") {
        fail("invalid assignment: " line)
        return
      }
      id=sec SUBSEP key
      if (id in overlay_line) {
        fail("duplicate assignment in overlay: " id)
        return
      }
      remember_section(sec)
      overlay_line[id]=line
      n=++overlay_key_count[sec]
      overlay_key[sec SUBSEP n]=key
    }
    function emit_missing(sec, i, key, id) {
      for (i=1; i<=overlay_key_count[sec]; i++) {
        key=overlay_key[sec SUBSEP i]
        id=sec SUBSEP key
        if (!(id in applied)) {
          print overlay_line[id]
          applied[id]=1
        }
      }
    }
    function section_path(sec, path) {
      path=sec
      sub(/^\[\[/, "", path)
      sub(/\]\]$/, "", path)
      sub(/^\[/, "", path)
      sub(/\]$/, "", path)
      return path
    }
    function emit_missing_parents(child, i, sec, child_path, sec_path) {
      child_path=section_path(child)
      for (i=1; i<=overlay_section_count; i++) {
        sec=overlay_sections[i]
        if (sec == "" || (sec in target_section_seen)) continue
        sec_path=section_path(sec)
        if (index(child_path, sec_path ".") == 1) {
          print ""
          print sec
          emit_missing(sec)
          target_section_seen[sec]=1
        }
      }
    }

    # First pass: collect the repository overlay.
    FNR == NR {
      raw=$0
      t=trim(raw)
      if (t == "" || t ~ /^#/) next
      h=header(raw)
      if (h != "") {
        overlay_section=h
        remember_section(h)
        next
      }
      if (index(raw, "=") > 0) {
        remember_assignment(overlay_section, raw)
        next
      }
      fail("unsupported overlay line: " raw)
      next
    }

    # Second pass: replace managed assignments and preserve everything else.
    {
      raw=$0
      h=header(raw)
      if (h != "") {
        emit_missing(target_section)
        emit_missing_parents(h)
        target_section=h
        target_section_seen[h]=1
        print raw
        next
      }
      if (index(raw, "=") > 0) {
        key=key_of(raw)
        id=target_section SUBSEP key
        if (id in overlay_line) {
          print overlay_line[id]
          applied[id]=1
        } else {
          print raw
        }
        next
      }
      print raw
    }

    END {
      if (failed) exit 2
      emit_missing(target_section)
      target_section_seen[""]=1
      for (i=1; i<=overlay_section_count; i++) {
        sec=overlay_sections[i]
        if (sec == "" || (sec in target_section_seen)) continue
        print ""
        print sec
        emit_missing(sec)
      }
    }
  ' "$src" "$dst"
}

codex_config_overlay_applied() { # codex_config_overlay_applied <仓库 overlay> <本机 config.toml>
  local src="$1" dst="$2" tmp result
  [ -f "$src" ] && [ -f "$dst" ] || return 1
  if ! tmp="$(mktemp "${TMPDIR:-/tmp}/agent-kit-codex-check.XXXXXX")"; then return 1; fi
  if ! toml_overlay_merge "$src" "$dst" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  cmp -s "$tmp" "$dst"
  result=$?
  rm -f -- "$tmp"
  return "$result"
}

install_codex_config() { # install_codex_config <仓库 overlay> <本机 config.toml>
  local src="$1" dst="$2" backup tmp
  if [ ! -f "$src" ]; then warn "config.toml: 源不存在 $src"; return; fi

  if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
    run mkdir -p -- "$(dirname "$dst")"
    run cp -- "$src" "$dst"
    say "+ config.toml"
    return
  fi
  if codex_config_overlay_applied "$src" "$dst"; then
    say "= config.toml 的仓库设置已生效"
    return
  fi

  if [ "$FORCE" = 1 ]; then
    backup="$dst.bak.$STAMP"
    if ! run cp -p -- "$dst" "$backup"; then
      warn "config.toml: 无法备份到 $backup，已跳过合并"
      return
    fi
    say "~ config.toml: 原文件已备份为 $(basename "$backup")"
  fi
  if [ "$DRY" = 1 ]; then
    say "~ config.toml 将合并仓库设置"
    return
  fi

  if ! tmp="$(mktemp "${dst}.tmp.XXXXXX")"; then
    warn "config.toml: 无法创建临时文件，已跳过合并"
    return
  fi
  if ! cp -p -- "$dst" "$tmp"; then
    rm -f -- "$tmp"
    warn "config.toml: 无法准备临时文件，已跳过合并"
    return
  fi
  if ! toml_overlay_merge "$src" "$dst" > "$tmp"; then
    rm -f -- "$tmp"
    warn "config.toml: 合并失败，原文件未改动"
    return
  fi
  if ! mv -- "$tmp" "$dst"; then
    rm -f -- "$tmp"
    warn "config.toml: 无法替换原文件"
    return
  fi
  say "~ config.toml 已合并仓库设置"
}

status_codex_config() { # status_codex_config <仓库 overlay> <本机 config.toml>
  local src="$1" dst="$2"
  if [ ! -f "$src" ]; then warn "config.toml: 源不存在 $src"; return; fi
  if [ ! -f "$dst" ]; then
    warn "config.toml 未安装"
    return
  fi
  if codex_config_overlay_applied "$src" "$dst"; then
    say "= config.toml 的仓库设置已生效"
  else
    warn "config.toml 的仓库设置未完全生效 —— 运行 ./install.sh --target codex 合并"
  fi
}

link_skills() { # link_skills <目标 skills 目录>
  local into="$1" d n
  for d in "$REPO"/skills/*/; do n="$(basename "$d")"; link "${d%/}" "$into/$n" "skill $n"; done
  if [ "$VENDOR" = 1 ]; then
    for d in "$REPO"/vendor/skills/*/; do n="$(basename "$d")"; link "${d%/}" "$into/$n" "vendor skill $n"; done
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
    link_plugin_file "$f" "$into/$rel" "$label $rel"
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
      if linked_to "$f" "$dst"; then
        say "= plugin $name $rel → 仓库"
      elif [ -e "$dst" ] || [ -L "$dst" ]; then
        warn "plugin $name $rel 存在但不指向仓库"
      else
        warn "plugin $name $rel 未安装"
      fi
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
  install_settings "$REPO/claude/settings.json" "$CLAUDE_DIR/settings.json"
  link_skills "$CLAUDE_DIR/skills"
  link_dir_files "$REPO/claude/agents"   "$CLAUDE_DIR/agents"   "agent"
  link_dir_files "$REPO/claude/commands" "$CLAUDE_DIR/commands" "command"
  install_plugin_files
}

install_codex() {
  echo "→ $CODEX_DIR"
  link "$REPO/codex/AGENTS.md" "$CODEX_DIR/AGENTS.md" "AGENTS.md"
  link_skills "$CODEX_DIR/skills"
  install_codex_config "$REPO/codex/config.toml.tmpl" "$CODEX_DIR/config.toml"
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
  local base="$1" doc="$2" p n ok=0 bad=0
  echo "→ $base"
  if owned_by_repo "$base/$doc"; then say "= $doc → 仓库"
  elif [ -e "$base/$doc" ]; then warn "$doc 存在但不指向仓库"
  else warn "$doc 未安装"; fi
  for n in skills agents commands; do
    [ -d "$base/$n" ] || continue
    ok=0; bad=0
    for p in "$base/$n"/*; do
      [ -e "$p" ] || [ -L "$p" ] || continue
      if owned_by_repo "$p"; then ok=$((ok+1)); else bad=$((bad+1)); fi
    done
    say "$n/: $ok 个来自仓库$([ $bad -gt 0 ] && echo "，$bad 个来自别处")"
  done
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
    if want_claude; then status_of "$CLAUDE_DIR" CLAUDE.md; status_settings "$REPO/claude/settings.json" "$CLAUDE_DIR/settings.json"; status_plugin_files; fi
    if want_codex;  then status_of "$CODEX_DIR" AGENTS.md; status_codex_config "$REPO/codex/config.toml.tmpl" "$CODEX_DIR/config.toml"; fi
    ;;
esac

[ "$rc" = 0 ] && echo "完成。" || echo "完成，但有上面标 ! 的项需要你确认。"
exit "$rc"

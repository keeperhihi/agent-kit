#!/usr/bin/env bash
# 把本仓库安装到 ~/.claude（默认）和/或 ~/.codex。
# settings.json 和 Codex config.toml 的受管键与仓库三方同步；其他受管文件使用符号链接。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="$HOME/.codex"
CLAUDE_BACKUP_ROOT="$CLAUDE_DIR/.agent-kit-backups"
CODEX_BACKUP_ROOT="$CODEX_DIR/.agent-kit-backups"
CLAUDE_STATE_DIR="$CLAUDE_DIR/.agent-kit-state"
CODEX_STATE_DIR="$CODEX_DIR/.agent-kit-state"

TARGET=claude
MODE=install
DRY=0
FORCE=0
VENDOR=0
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_SESSION="$STAMP-$$"
rc=0

usage() {
  cat <<'EOF'
用法: ./install.sh [选项]

  --target claude|codex|both   安装目标（默认 claude）
  --with-vendor                同时安装 vendor/skills 中的第三方 skill（默认跳过）
  --dry-run                    只打印将要做什么
  --force                      覆盖已有目标前备份；备份放在对应配置目录的 .agent-kit-backups/<run-id>/
                               settings.json / config.toml 两边都改过的键以仓库为准
  --pull                       把本机改过的受管设置（如在 CLI 里改的）写回仓库，用 git diff 审阅
  --status                     只检查安装状态，不改动任何东西
  --uninstall                  移除本仓库装出去的符号链接（不动普通文件）
  -h, --help                   显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?--target 需要参数}"; shift 2 ;;
    --with-vendor) VENDOR=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --status) MODE=status; shift ;;
    --pull) MODE=pull; shift ;;
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

backup_target() { # backup_target <move|copy> <源路径> <显示名>
  local mode="$1" src="$2" name="$3" backup
  backup="$(backup_path "$src")"
  if [ "$DRY" = 0 ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
    warn "$name: 备份目标已存在，拒绝覆盖: $backup"
    return 1
  fi
  if ! run mkdir -p -- "$(dirname "$backup")"; then
    warn "$name: 无法创建备份目录: $(dirname "$backup")"
    return 1
  fi
  case "$mode" in
    move)
      if ! run mv -- "$src" "$backup"; then
        warn "$name: 无法备份到 $backup"
        return 1
      fi
      ;;
    copy)
      if ! run cp -p -- "$src" "$backup"; then
        warn "$name: 无法备份到 $backup"
        return 1
      fi
      ;;
    *)
      warn "$name: 未知备份方式: $mode"
      return 1
      ;;
  esac
  say "~ $name: 原文件已备份到 $backup"
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
      backup_target move "$dst" "$name" || return
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

# settings.json 与 config.toml 的受管键做三方同步：比较仓库 overlay、本机文件和
# 上次同步时记下的值（同步记录，存放在配置目录的 .agent-kit-state/）。
#   只有仓库改了          → install 应用到本机
#   只有本机改了或删了    → 保留本机；--pull 写回仓库
#   两边都改了            → 冲突；--pull 取本机，--force 取仓库
# 还没有同步记录时，install/status 以仓库为准，--pull 以本机为准。
# 比较结果按行报告，字段以 \037 分隔：状态、键、仓库值、本机值、本机是否有值。
SEP=$'\037'
SYNC_PENDING=0
SYNC_EXTRAS=""

dry_word() { if [ "$DRY" = 1 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

print_sync_report() { # print_sync_report <显示名> <模式>；从标准输入读取比较结果
  local name="$1" mode="$2" state key rv lv lh l extras=""
  SYNC_PENDING=0
  while IFS="$SEP" read -r state key rv lv lh; do
    [ -n "$state" ] || continue
    if [ "$state" = extra ]; then extras="${extras:+$extras, }$key"; continue; fi
    SYNC_PENDING=$((SYNC_PENDING + 1))
    if [ "$lh" = 1 ]; then l="$lv"; else l="（未设置）"; fi
    case "$state:$mode" in
      repo:install)
        if [ "$DRY" = 1 ]; then say "~ $name: $key 将改为仓库值 ${rv}（本机 ${l}）"
        else say "+ $name: $key = ${rv}（原为 ${l}）"; fi ;;
      repo:pull) say "~ $name: $key 的仓库值 $rv 尚未应用到本机，不写回" ;;
      repo:*) warn "$name: $key 的仓库值 $rv 尚未应用（本机 ${l}）—— 运行 ./install.sh" ;;
      local:pull) say "← $name: $key = $l $(dry_word 将写回 已写回)仓库" ;;
      local:*) say "~ $name: $key 本机改为 ${l}（仓库 ${rv}）—— --pull 可写回仓库" ;;
      deleted:pull) say "← $name: $key $(dry_word 将从仓库移除 已从仓库移除)" ;;
      deleted:*) say "~ $name: $key 本机已删除（仓库 ${rv}）—— --pull 可从仓库移除" ;;
      conflict:pull)
        if [ "$lh" = 1 ]; then say "← $name: $key = $l $(dry_word 将写回 已写回)仓库（仓库原为 ${rv}）"
        else say "← $name: $key $(dry_word 将从仓库移除 已从仓库移除)（仓库原为 ${rv}）"; fi ;;
      conflict:install)
        if [ "$FORCE" != 1 ]; then warn "$name: $key 两边都改了：仓库 ${rv}，本机 $l —— 已跳过；--pull 取本机，--force 取仓库"
        elif [ "$DRY" = 1 ]; then say "~ $name: $key 将改为仓库值 ${rv}（覆盖本机 ${l}）"
        else say "+ $name: $key = ${rv}（覆盖本机 ${l}）"; fi ;;
      conflict:*) warn "$name: $key 两边都改了：仓库 ${rv}，本机 $l —— --pull 取本机，--force 取仓库" ;;
      manual:*)
        if [ "$rv" = multiline ]; then warn "$name: $key 本机的值跨多行，无法自动同步，请手动处理"
        else warn "$name: $key 所在的表由点号键定义，无法自动插入，请手动处理"; fi ;;
    esac
  done
  SYNC_EXTRAS="$extras"
}

print_sync_extras() {
  if [ -n "$SYNC_EXTRAS" ]; then say "  本机另有未纳入仓库的键：$SYNC_EXTRAS"; fi
}

save_base() { # save_base <仓库 overlay> <同步记录>；首次安装时 overlay 本身就是同步记录
  if [ "$DRY" = 1 ]; then return 0; fi
  if ! { mkdir -p -- "$(dirname "$2")" && cp -- "$1" "$2"; }; then warn "无法写入同步记录 $2"; fi
}

write_json() { # write_json <JSON> <jq 过滤器> <目标文件> <显示名>
  local json="$1" filter="$2" dst="$3" name="$4" tmp
  if ! mkdir -p -- "$(dirname "$dst")" || ! tmp="$(mktemp "${dst}.tmp.XXXXXX")"; then
    warn "$name: 无法创建临时文件，未写入"
    return 1
  fi
  if [ -f "$dst" ]; then cp -p -- "$dst" "$tmp" || true; fi
  if printf '%s\n' "$json" | jq "$filter" > "$tmp" && mv -- "$tmp" "$dst"; then return 0; fi
  rm -f -- "$tmp"
  warn "$name: 写入失败，原文件未改动"
  return 1
}

IFS= read -r -d '' SETTINGS_SYNC_JQ <<'JQ' || true
def present($p):
  if ($p | length) == 0 then true
  else (try (getpath($p[:-1]) | type == "object" and has($p[-1])) catch false)
  end;
# 叶子键：对象之外的值；数组整体算一个值。
def leaves: [paths(type != "object") | select(all(.[]; type == "string"))];
def show: tojson | if length > 60 then .[:57] + "..." else . end;
def prune($p):
  reduce range(($p | length) - 1; 0; -1) as $k (.;
    if getpath($p[:$k]) == {} then delpaths([$p[:$k]]) else . end);

$repo[0] as $R | $local[0] as $L
| (if $hasbase then $base[0]
   elif $mode == "pull" then
     reduce ($R | leaves)[] as $p ({}; if ($L | present($p)) then setpath($p; $R | getpath($p)) else . end)
   else $L end) as $B
| [ ($R | leaves)[] as $p
    | ($L | present($p)) as $lh
    | ($B | present($p)) as $bh
    | { p: $p, r: ($R | getpath($p)),
        lh: $lh, l: (if $lh then $L | getpath($p) else null end),
        bh: $bh, b: (if $bh then $B | getpath($p) else null end) }
    | .state = (if .lh and .l == .r then "same"
                elif (.bh | not) then (if .lh then "conflict" else "repo" end)
                elif .lh and .l == .b then "repo"
                elif .r == .b then (if .lh then "local" else "deleted" end)
                else "conflict" end) ] as $items
| (if $mode == "install" then
     reduce ($items[] | select(.state == "repo" or ($force and .state == "conflict"))) as $i
       ($L; setpath($i.p; $i.r))
   else $L end) as $L2
| (if $mode == "pull" then
     reduce ($items[] | select(.state == "local" or .state == "deleted" or .state == "conflict")) as $i
       ($R; if $i.lh then setpath($i.p; $i.l) else delpaths([$i.p]) | prune($i.p) end)
   else $R end) as $R2
| { local: $L2, repo: $R2,
    local_changed: ($L2 != $L), repo_changed: ($R2 != $R),
    base: (reduce ($R2 | leaves)[] as $p ({};
             ($R2 | getpath($p)) as $v
             | if ($L2 | present($p)) and ($L2 | getpath($p)) == $v then setpath($p; $v)
               elif $hasbase and ($B | present($p)) then setpath($p; $B | getpath($p))
               else . end)),
    report: ([ $items[] | select(.state != "same")
               | [.state, (.p | join(".")), (.r | show),
                  (if .lh then .l | show else "" end), (if .lh then "1" else "0" end)]
               | join("\u001f") ]
             + ([ ($L | leaves)[] as $p
                  | select(($R | present($p)) | not)
                  | [ range(1; ($p | length) + 1) as $k | $p[:$k] as $q
                      | select(($R | present($q)) | not) | $q ][0]
                  | join(".") ] | unique | map("extra\u001f" + .))) }
JQ

sync_settings() { # sync_settings <install|status|pull> <仓库 overlay> <本机设置> <同步记录>
  local mode="$1" src="$2" dst="$3" base="$4" has_base=false base_in="$2" force=false result ok=1
  if [ ! -f "$src" ]; then warn "settings.json: 源不存在 $src"; return 0; fi
  require_jq || return 0
  if ! json_object "$src"; then
    warn "settings.json: $src 不是有效的 JSON 对象，已跳过"
    return 0
  fi
  if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
    case "$mode" in
      install)
        run mkdir -p -- "$(dirname "$dst")"
        run cp -- "$src" "$dst"
        save_base "$src" "$base"
        say "+ settings.json"
        ;;
      status) warn "settings.json 未安装" ;;
      pull) warn "settings.json: 本机没有 ${dst}，无可写回" ;;
    esac
    return 0
  fi
  if ! json_object "$dst"; then
    warn "settings.json: $dst 不是有效的 JSON 对象，已跳过"
    return 0
  fi
  if [ -f "$base" ]; then has_base=true; base_in="$base"; fi
  if [ "$FORCE" = 1 ]; then force=true; fi
  if ! result="$(jq -n --slurpfile repo "$src" --slurpfile local "$dst" --slurpfile base "$base_in" \
      --argjson hasbase "$has_base" --argjson force "$force" --arg mode "$mode" "$SETTINGS_SYNC_JQ")"; then
    warn "settings.json: 无法比较本机与仓库设置，已跳过"
    return 0
  fi
  print_sync_report settings.json "$mode" <<< "$(printf '%s\n' "$result" | jq -r '.report[]')"
  case "$mode" in
    install)
      if [ "$(printf '%s\n' "$result" | jq '.local_changed')" = true ]; then
        if [ "$DRY" = 1 ]; then
          say "~ settings.json 将合并仓库设置"
        elif [ "$FORCE" = 1 ] && ! backup_target copy "$dst" "settings.json"; then
          ok=0
        elif write_json "$result" '.local' "$dst" settings.json; then
          say "~ settings.json 已合并仓库设置"
        else
          ok=0
        fi
      elif [ "$SYNC_PENDING" = 0 ]; then
        say "= settings.json 的仓库设置已生效"
      fi
      ;;
    pull)
      if [ "$(printf '%s\n' "$result" | jq '.repo_changed')" = true ]; then
        if [ "$DRY" = 1 ]; then
          say "~ 将写回仓库 $src"
        elif write_json "$result" '.repo' "$src" "仓库 settings.json"; then
          say "~ 已写回仓库 ${src}，用 git diff 查看"
        else
          ok=0
        fi
      elif [ "$SYNC_PENDING" = 0 ]; then
        say "= settings.json 没有需要写回仓库的改动"
      fi
      ;;
    status)
      if [ "$SYNC_PENDING" = 0 ]; then say "= settings.json 的仓库设置已生效"; fi
      print_sync_extras
      ;;
  esac
  if [ "$mode" != status ] && [ "$DRY" = 0 ] && [ "$ok" = 1 ]; then
    write_json "$result" '.base' "$base" "settings.json 同步记录" || true
  fi
}

# config.toml 的同步不依赖 TOML 解析器：逐行识别表头和赋值，表头与键名按 TOML 语义
# 规范化后比较（["model_providers"."cm"] 与 [model_providers.cm] 是同一张表），
# 值按去掉注释后的文本比较。本机文件之外的内容（注释、本机独有的键和表）原样保留。
# 输入依次为仓库 overlay、同步记录（没有时为 /dev/null）、本机文件两遍：
# 第一遍收集本机的值，第二遍输出合并结果。install 把新的本机文件写到标准输出，
# pull 把新的 overlay 写到标准输出；比较结果写到 AK_REPORT，新的同步记录写到 AK_BASE_OUT。
IFS= read -r -d '' CODEX_SYNC_AWK <<'AWK' || true
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function fail(msg) { print "TOML overlay error: " msg > "/dev/stderr"; failed = 1 }
function show(v) { gsub(/\n/, " ", v); if (length(v) > 60) v = substr(v, 1, 57) "..."; return v }
function join_path(a, b) { return (a == "") ? b : (a "." b) }

# 返回注释之前的内容，并跟踪多行字符串（ml）与括号深度（depth），用来识别跨行的值。
function scan(s,    n, i, j, c, q, out) {
  n = length(s); out = ""; i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (ml) {
      q = (ml == 1) ? "\"\"\"" : "'''"
      if (substr(s, i, 3) == q) { out = out q; i += 3; ml = 0; continue }
      if (ml == 1 && c == "\\") { out = out substr(s, i, 2); i += 2; continue }
      out = out c; i++; continue
    }
    if (c == "#") break
    if (substr(s, i, 3) == "\"\"\"") { ml = 1; out = out "\"\"\""; i += 3; continue }
    if (substr(s, i, 3) == "'''") { ml = 2; out = out "'''"; i += 3; continue }
    if (c == "\"" || c == "'") {
      for (j = i + 1; j <= n; j++) {
        if (c == "\"" && substr(s, j, 1) == "\\") { j++; continue }
        if (substr(s, j, 1) == c) break
      }
      out = out substr(s, i, j - i + 1); i = j + 1; continue
    }
    if (c == "[" || c == "{") depth++
    else if (c == "]" || c == "}") depth--
    out = out c; i++
  }
  return out
}

# 第一个不在引号内的 "=" 的位置。
function eq_pos(s,    n, i, c, q) {
  n = length(s); q = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q != "") {
      if (q == "\"" && c == "\\") i++
      else if (c == q) q = ""
      continue
    }
    if (c == "\"" || c == "'") q = c
    else if (c == "=") return i
  }
  return 0
}

# 规范化点号键的一段：去掉空白；只含 A-Za-z0-9_- 的段去掉引号。
function canon_seg(seg,    q, inner) {
  seg = trim(seg); q = substr(seg, 1, 1)
  if (length(seg) >= 2 && (q == "\"" || q == "'") && substr(seg, length(seg), 1) == q) {
    inner = substr(seg, 2, length(seg) - 2)
    if (inner ~ /^[A-Za-z0-9_-]+$/) return inner
    if (q == "'") return "\"" inner "\""
  }
  return seg
}

function segs(s, arr,    n, i, c, q, seg, k) {
  n = length(s); q = ""; seg = ""; k = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q != "") {
      seg = seg c
      if (q == "\"" && c == "\\") { i++; seg = seg substr(s, i, 1) }
      else if (c == q) q = ""
      continue
    }
    if (c == "\"" || c == "'") { q = c; seg = seg c }
    else if (c == ".") { arr[++k] = canon_seg(seg); seg = "" }
    else seg = seg c
  }
  arr[++k] = canon_seg(seg)
  return k
}

function canon(s,    arr, n, i, out) {
  n = segs(s, arr); out = arr[1]
  for (i = 2; i <= n; i++) out = out "." arr[i]
  return out
}

function pending(s,    i, id) {
  for (i = 1; i <= rskn[s]; i++) {
    id = rsk[s, i]
    if ((id in apply) && !(id in lhas) && !(id in done)) return 1
  }
  return 0
}

# 输出仓库表 s 中本机缺少、需要补上的键。
function flush(s,    i, id) {
  if (!(s in rsec_seen)) return
  for (i = 1; i <= rskn[s]; i++) {
    id = rsk[s, i]
    if ((id in apply) && !(id in lhas) && !(id in done)) { print rkey[id] " = " rval[id]; done[id] = 1 }
  }
}

# 表末尾的空行和注释先暂存，补上的键插在它们之前，紧跟所属表的最后一个键。
function release(    i) { for (i = 1; i <= nh; i++) print held[i]; nh = 0 }

# 本机缺少的仓库表若是表头 h 的父表，插在 h 之前。
function parents(h,    i, s) {
  for (i = 2; i <= nrs; i++) {
    s = rsec[i]
    if ((s in lsec_seen) || (s in emitted)) continue
    if (index(h, s ".") == 1 && pending(s)) { print ""; print rhdr[s]; flush(s); emitted[s] = 1 }
  }
}

function decide(    i, id, r, l, b, lh, bh, st) {
  decided = 1
  for (i = 1; i <= nk; i++) {
    id = kid[i]; r = rval[id]; lh = (id in lhas); l = lh ? lval[id] : ""
    if (has_base) { bh = (id in bval); b = bh ? bval[id] : "" }
    else if (mode == "pull") { bh = lh; b = r }
    else { bh = lh; b = l }
    if (lh && (id in lmulti)) st = "multiline"
    else if (lh && l == r) st = "same"
    else if (!bh) st = lh ? "conflict" : "repo"
    else if (lh && l == b) st = "repo"
    else if (r == b) st = lh ? "local" : "deleted"
    else st = "conflict"
    if (!lh && (st == "repo" || (st == "conflict" && force)) && (rsecof[id] in dotted)) st = "dotted"
    if (st == "same") continue
    if (st == "multiline" || st == "dotted") {
      printf "manual%s%s%s%s%s%s0\n", SEP, id, SEP, st, SEP, SEP > REPORT
      continue
    }
    if (mode == "install" && (st == "repo" || (st == "conflict" && force))) apply[id] = 1
    if (mode == "pull" && (st == "local" || st == "deleted" || st == "conflict")) take[id] = 1
    printf "%s%s%s%s%s%s%s%s%d\n", st, SEP, id, SEP, show(r), SEP, (lh ? show(l) : ""), SEP, lh > REPORT
  }
  extras()
}

# 本机独有的键只报告名字（取第一个不属于仓库的路径段），不报告值。
function extras(    i, j, n, id, pre, ks2) {
  for (i = 1; i <= nk; i++) {
    n = segs(kid[i], ks2); pre = ""
    for (j = 1; j <= n; j++) { pre = join_path(pre, ks2[j]); rpre[pre] = 1 }
  }
  for (i = 1; i <= nl; i++) {
    id = lid[i]
    if (id in rval) continue
    n = segs(id, ks2); pre = ""
    for (j = 1; j <= n; j++) { pre = join_path(pre, ks2[j]); if (!(pre in rpre)) break }
    if (!(pre in xseen)) { xseen[pre] = 1; printf "extra%s%s\n", SEP, pre > REPORT }
  }
}

# 同步记录：操作后两边一致的键记为该值；仍不一致的键保留原记录。
function write_base(    i, j, s, id, fr, fl, flh, v, hdr) {
  printf "" > BASE_OUT
  for (i = 1; i <= nrs; i++) {
    s = rsec[i]; hdr = (s == "")
    for (j = 1; j <= rskn[s]; j++) {
      id = rsk[s, j]
      if (id in take) { if (!(id in lhas)) continue; fr = lval[id] } else fr = rval[id]
      if (id in apply) { flh = 1; fl = rval[id] } else { flh = (id in lhas); fl = flh ? lval[id] : "" }
      if (flh && fl == fr) v = fr
      else if (has_base && (id in bval)) v = bval[id]
      else continue
      if (!hdr) { print "" > BASE_OUT; print rhdr[s] > BASE_OUT; hdr = 1 }
      print rkey[id] " = " v > BASE_OUT
    }
  }
  close(BASE_OUT)
}

BEGIN {
  SEP = "\037"
  RF = ENVIRON["AK_REPO"]; BF = ENVIRON["AK_BASE"]; LF = ENVIRON["AK_LOCAL"]
  REPORT = ENVIRON["AK_REPORT"]; BASE_OUT = ENVIRON["AK_BASE_OUT"]
  nrs = 1; rsec[1] = ""; rsec_seen[""] = 1; rhdr[""] = ""; osec = ""
}

FNR == 1 { ml = 0; depth = 0; cont = 0; sec = ""; if (FILENAME == LF) lpass++ }

FILENAME == RF {
  raw = $0; rline[++nrl] = raw; rlid[nrl] = ""
  t = trim(scan(raw))
  if (ml || depth) { fail("multi-line value in overlay: " raw); ml = 0; depth = 0; next }
  if (t == "") next
  if (substr(t, 1, 2) == "[[") { fail("array of tables in overlay: " raw); next }
  if (t ~ /^\[.*\]$/) {
    sec = canon(substr(t, 2, length(t) - 2))
    if (!(sec in rsec_seen)) { rsec_seen[sec] = 1; rsec[++nrs] = sec; rhdr[sec] = t }
    next
  }
  p = eq_pos(t)
  if (!p) { fail("unsupported overlay line: " raw); next }
  key = trim(substr(t, 1, p - 1)); id = join_path(sec, canon(key))
  if (id in rval) { fail("duplicate assignment in overlay: " id); next }
  rval[id] = trim(substr(t, p + 1)); rkey[id] = key; rsecof[id] = sec
  kid[++nk] = id; rsk[sec, ++rskn[sec]] = id
  rlid[nrl] = id; ind = raw; sub(/[^[:space:]].*$/, "", ind); rind[nrl] = ind
  next
}

FILENAME == BF {
  t = trim(scan($0))
  if (ml || depth) { ml = 0; depth = 0; next }
  if (t == "") next
  if (t ~ /^\[.*\]$/) { sec = canon(substr(t, 2, length(t) - 2)); next }
  p = eq_pos(t)
  if (p) bval[join_path(sec, canon(trim(substr(t, 1, p - 1))))] = trim(substr(t, p + 1))
  next
}

FILENAME == LF && lpass == 1 {
  t = trim(scan($0))
  if (cont) {
    if (cid != "") lval[cid] = lval[cid] "\n" t
    if (!ml && depth <= 0) cont = 0
    next
  }
  if (t == "") next
  if (substr(t, 1, 2) == "[[") { sec = "[[" FNR "]]"; next }
  if (t ~ /^\[.*\]$/) { sec = canon(substr(t, 2, length(t) - 2)); lsec_seen[sec] = 1; next }
  p = eq_pos(t)
  if (!p) next
  n = segs(trim(substr(t, 1, p - 1)), ks); id = sec
  for (i = 1; i <= n; i++) { id = join_path(id, ks[i]); if (i < n) dotted[id] = 1 }
  cid = ""
  if (substr(sec, 1, 2) != "[[") { cid = id; lhas[id] = 1; lval[id] = trim(substr(t, p + 1)); lid[++nl] = id }
  if (ml || depth > 0) { cont = 1; if (cid != "") lmulti[cid] = 1 }
  next
}

FILENAME == LF && lpass == 2 {
  if (!decided) decide()
  if (mode != "install") next
  raw = $0; t = trim(scan(raw))
  if (cont) { print raw; if (!ml && depth <= 0) cont = 0; next }
  if (t == "") { held[++nh] = raw; next }
  if (substr(t, 1, 2) == "[[") { flush(osec); release(); osec = "[[" FNR "]]"; print raw; next }
  if (t ~ /^\[.*\]$/) {
    h = canon(substr(t, 2, length(t) - 2))
    flush(osec); parents(h); release(); osec = h
    print raw; next
  }
  release()
  p = eq_pos(t)
  if (p) {
    if (ml || depth > 0) cont = 1
    key = trim(substr(t, 1, p - 1)); id = join_path(osec, canon(key))
    if ((id in apply) && !(id in done)) {
      ind = raw; sub(/[^[:space:]].*$/, "", ind)
      print ind key " = " rval[id]; done[id] = 1
      next
    }
  }
  print raw
}

END {
  if (failed) exit 2
  if (!decided) decide()
  if (mode == "install") {
    flush(osec); release()
    for (i = 2; i <= nrs; i++) {
      s = rsec[i]
      if ((s in lsec_seen) || (s in emitted) || !pending(s)) continue
      print ""; print rhdr[s]; flush(s); emitted[s] = 1
    }
  } else if (mode == "pull") {
    for (i = 1; i <= nrl; i++) {
      id = rlid[i]
      if (id != "" && (id in take)) { if (id in lhas) print rind[i] rkey[id] " = " lval[id]; continue }
      print rline[i]
    }
  }
  write_base()
  close(REPORT)
}
AWK

sync_codex_config() { # sync_codex_config <install|status|pull> <仓库 overlay> <本机 config.toml> <同步记录>
  local mode="$1" src="$2" dst="$3" base="$4" has_base=0 base_in=/dev/null target="" out="" report base_out ok=1
  if [ ! -f "$src" ]; then warn "config.toml: 源不存在 $src"; return 0; fi
  if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
    case "$mode" in
      install)
        run mkdir -p -- "$(dirname "$dst")"
        run cp -- "$src" "$dst"
        save_base "$src" "$base"
        say "+ config.toml"
        ;;
      status) warn "config.toml 未安装" ;;
      pull) warn "config.toml: 本机没有 ${dst}，无可写回" ;;
    esac
    return 0
  fi
  if [ -f "$base" ]; then has_base=1; base_in="$base"; fi
  case "$mode" in install) target="$dst" ;; pull) target="$src" ;; esac
  if ! report="$(mktemp "${TMPDIR:-/tmp}/agent-kit-report.XXXXXX")"; then
    warn "config.toml: 无法创建临时文件，已跳过"
    return 0
  fi
  if ! base_out="$(mktemp "${TMPDIR:-/tmp}/agent-kit-base.XXXXXX")"; then
    rm -f -- "$report"
    warn "config.toml: 无法创建临时文件，已跳过"
    return 0
  fi
  if [ -n "$target" ]; then
    if ! out="$(mktemp "${target}.tmp.XXXXXX")"; then
      rm -f -- "$report" "$base_out"
      warn "config.toml: 无法创建临时文件，已跳过"
      return 0
    fi
    cp -p -- "$target" "$out" 2>/dev/null || true
  fi
  if ! AK_REPO="$src" AK_BASE="$base_in" AK_LOCAL="$dst" AK_REPORT="$report" AK_BASE_OUT="$base_out" \
      awk -v mode="$mode" -v force="$FORCE" -v has_base="$has_base" "$CODEX_SYNC_AWK" \
      "$src" "$base_in" "$dst" "$dst" > "${out:-/dev/null}"; then
    rm -f -- "$report" "$base_out" ${out:+"$out"}
    case "$mode" in
      install) warn "config.toml: 合并失败，原文件未改动" ;;
      pull) warn "config.toml: 写回失败，仓库模板未改动" ;;
      status) warn "config.toml: 无法比较本机与仓库模板" ;;
    esac
    return 0
  fi
  print_sync_report config.toml "$mode" < "$report"
  case "$mode" in
    install)
      if ! cmp -s "$out" "$dst"; then
        if [ "$DRY" = 1 ]; then
          say "~ config.toml 将合并仓库设置"
        elif [ "$FORCE" = 1 ] && ! backup_target copy "$dst" "config.toml"; then
          ok=0
        elif mv -- "$out" "$dst"; then
          out=""
          say "~ config.toml 已合并仓库设置"
        else
          ok=0
          warn "config.toml: 无法替换原文件"
        fi
      elif [ "$SYNC_PENDING" = 0 ]; then
        say "= config.toml 的仓库设置已生效"
      fi
      ;;
    pull)
      if ! cmp -s "$out" "$src"; then
        if [ "$DRY" = 1 ]; then
          say "~ 将写回仓库 $src"
        elif mv -- "$out" "$src"; then
          out=""
          say "~ 已写回仓库 ${src}，用 git diff 查看"
        else
          ok=0
          warn "config.toml: 无法写回仓库模板"
        fi
      elif [ "$SYNC_PENDING" = 0 ]; then
        say "= config.toml 没有需要写回仓库的改动"
      fi
      ;;
    status)
      if [ "$SYNC_PENDING" = 0 ]; then say "= config.toml 的仓库设置已生效"; fi
      print_sync_extras
      ;;
  esac
  if [ "$mode" != status ] && [ "$DRY" = 0 ] && [ "$ok" = 1 ]; then
    if ! { mkdir -p -- "$(dirname "$base")" && mv -- "$base_out" "$base"; }; then
      warn "config.toml: 无法写入同步记录 $base"
    fi
  fi
  rm -f -- "$report" "$base_out" ${out:+"$out"}
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
  sync_settings install "$REPO/claude/settings.json" "$CLAUDE_DIR/settings.json" "$CLAUDE_STATE_DIR/settings.json"
  link_skills "$CLAUDE_DIR/skills"
  link_dir_files "$REPO/claude/agents"   "$CLAUDE_DIR/agents"   "agent"
  link_dir_files "$REPO/claude/commands" "$CLAUDE_DIR/commands" "command"
  install_plugin_files
}

install_codex() {
  echo "→ $CODEX_DIR"
  link "$REPO/codex/AGENTS.md" "$CODEX_DIR/AGENTS.md" "AGENTS.md"
  link_skills "$CODEX_DIR/skills"
  sync_codex_config install "$REPO/codex/config.toml.tmpl" "$CODEX_DIR/config.toml" "$CODEX_STATE_DIR/config.toml"
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
    if want_claude; then status_of "$CLAUDE_DIR" CLAUDE.md; sync_settings status "$REPO/claude/settings.json" "$CLAUDE_DIR/settings.json" "$CLAUDE_STATE_DIR/settings.json"; status_plugin_files; fi
    if want_codex;  then status_of "$CODEX_DIR" AGENTS.md; sync_codex_config status "$REPO/codex/config.toml.tmpl" "$CODEX_DIR/config.toml" "$CODEX_STATE_DIR/config.toml"; fi
    ;;
  pull)
    if want_claude; then echo "→ $CLAUDE_DIR"; sync_settings pull "$REPO/claude/settings.json" "$CLAUDE_DIR/settings.json" "$CLAUDE_STATE_DIR/settings.json"; fi
    if want_codex;  then echo "→ $CODEX_DIR"; sync_codex_config pull "$REPO/codex/config.toml.tmpl" "$CODEX_DIR/config.toml" "$CODEX_STATE_DIR/config.toml"; fi
    ;;
esac

[ "$rc" = 0 ] && echo "完成。" || echo "完成，但有上面标 ! 的项需要你确认。"
exit "$rc"

#!/usr/bin/env bash
# 把本仓库复制到 Claude Code / Codex 的配置目录，装完不再依赖仓库。
# 每个配置目录的 .agent-kit/ 记下受管路径（managed）、它们第一次被接管前的原样（original/）
# 和要不要第三方 skills（with-vendor）。重装时把仓库里已经没有的路径放回原样，-r 把全部受管路径放回原样。
# 需兼容 macOS 自带的 Bash 3.2 和 BSD 工具。
set -euo pipefail
umask 077

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
pending=''
trap '[ -z "$pending" ] || rm -rf -- "$pending"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat <<'EOF'
用法: ./install.sh [claude] [codex] [--with-vendor | --without-vendor] [--cm-key KEY]
      ./install.sh -r [claude] [codex]

  claude, codex     只处理指定的客户端；都不写就两个都处理
  --with-vendor     同时安装 vendor/skills 里的第三方 skills
  --without-vendor  不装第三方 skills；两个都不写时沿用这台机器上次的选择
  --cm-key KEY      把 CodexManager 网关 key 写入 auth.json；不写时保留已有的
  -r                恢复成第一次安装之前的样子
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }

restore=0 vendor='' cm_key='' cm_key_set=0 clients=''
while [ $# -gt 0 ]; do
  case "$1" in
    claude|codex) case " $clients " in *" $1 "*) ;; *) clients="$clients $1" ;; esac ;;
    --with-vendor|--without-vendor)
      [ -z "$vendor" ] || [ "$vendor" = "$1" ] || { usage >&2; exit 2; }
      vendor="$1"
      ;;
    --cm-key)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      cm_key="$2" cm_key_set=1
      shift
      ;;
    -r) restore=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$clients" ] || clients='claude codex'
if [ "$restore" = 1 ] && { [ -n "$vendor" ] || [ "$cm_key_set" = 1 ]; }; then usage >&2; exit 2; fi
case " $clients " in *' codex '*) ;; *) [ "$cm_key_set" = 0 ] || die '--cm-key 只用于 Codex' ;; esac

config_dir() { # config_dir <客户端>
  local dir
  case "$1" in
    claude) dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    codex) dir="${CODEX_HOME:-$HOME/.codex}" ;;
  esac
  printf '%s\n' "${dir%/}"
}

targets() { # targets <客户端> <配置目录>：全部受管路径，相对配置目录
  local d
  case "$1" in
    claude) echo CLAUDE.md ;;
    codex) echo AGENTS.md; echo auth.json ;;
  esac
  if [ -d "$repo/$1" ]; then
    (cd "$repo/$1" && find . -type f ! -path '*/.*') | sed 's|^\./||'
  fi
  for d in "$repo"/skills/*/; do
    [ -d "$d" ] || continue
    echo "skills/$(basename "$d")"
  done
  [ -e "$2/.agent-kit/with-vendor" ] || return 0
  for d in "$repo"/vendor/skills/*/; do
    [ -d "$d" ] || continue
    echo "skills/$(basename "$d")"
  done
}

source_of() { # source_of <客户端> <受管路径>：仓库里的来源
  case "$2" in
    CLAUDE.md|AGENTS.md) printf '%s\n' "$repo/instructions.md" ;;
    skills/*) if [ -d "$repo/$2" ]; then printf '%s\n' "$repo/$2"; else printf '%s\n' "$repo/vendor/$2"; fi ;;
    *) printf '%s\n' "$repo/$1/$2" ;;
  esac
}

listed() { grep -Fxq -- "$2" <<< "$1"; } # listed <换行分隔的列表> <路径>

copy_into() { # copy_into <来源> <目标> <cp 参数>：先复制到目标旁边，再换上去
  local parent
  parent="$(dirname "$2")"
  mkdir -p "$parent"
  pending="$(mktemp -d "$parent/.agent-kit.XXXXXX")"
  cp "$3" "$1" "$pending/entry"
  rm -rf -- "$2"
  mv "$pending/entry" "$2"
  rmdir "$pending"
  pending=''
}

restore_entry() { # restore_entry <配置目录> <受管路径>：放回原样，原本没有就删掉
  local target="$1/$2" saved="$1/.agent-kit/original/$2"
  case "/$2/" in *//*|*/../*|*/./*) die "受管列表里有不安全的路径：$2" ;; esac
  rm -rf -- "$target"
  if exists "$saved"; then
    mkdir -p "$(dirname "$target")"
    mv "$saved" "$target"
  fi
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

has_cm_key() { # has_cm_key <auth.json>：apikey 格式，key 非空且不以 sk-（OpenAI 官方 key）开头
  [ -f "$1" ] &&
    grep -Eq '"auth_mode"[[:space:]]*:[[:space:]]*"apikey"' "$1" &&
    grep -Eq '"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"[^"]+"' "$1" &&
    ! grep -Eq '"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"sk-' "$1"
}

write_auth() { # write_auth <auth.json>
  if [ "$cm_key_set" = 0 ] && has_cm_key "$1"; then
    say '= auth.json：保留已有 key'
    return 0
  fi
  rm -rf -- "$1"
  { printf '{\n  "auth_mode": "apikey",\n  "OPENAI_API_KEY": '; json_string "$cm_key"; printf '\n}\n'; } > "$1"
  [ -n "$cm_key" ] || say "! auth.json 的 key 是空的，填好 CodexManager 网关 key 再用 Codex：$1"
}

install_client() { # install_client <客户端>
  local dir state list rel note=''
  dir="$(config_dir "$1")"
  state="$dir/.agent-kit"
  echo "→ $dir"
  mkdir -p "$state/original"
  touch "$state/managed"
  case "$vendor" in # 两个都没写就沿用上次的选择
    --with-vendor) touch "$state/with-vendor" ;;
    --without-vendor) rm -f "$state/with-vendor" ;;
  esac
  list="$(targets "$1" "$dir" | sort -u)"

  # 第一次接管的路径：先存原样再登记。存过的原样不再覆盖。
  while IFS= read -r rel; do
    listed "$(cat "$state/managed")" "$rel" && continue
    if exists "$dir/$rel" && ! exists "$state/original/$rel"; then
      copy_into "$dir/$rel" "$state/original/$rel" -RPp
      say "~ $rel（原样已存入 .agent-kit）"
    fi
    printf '%s\n' "$rel" >> "$state/managed"
  done <<< "$list"

  # 仓库里已经没有的路径：放回原样。
  while IFS= read -r rel; do
    listed "$list" "$rel" && continue
    restore_entry "$dir" "$rel"
    say "- $rel"
  done < "$state/managed"

  while IFS= read -r rel; do
    if [ "$rel" = auth.json ]; then
      write_auth "$dir/$rel"
    else
      copy_into "$(source_of "$1" "$rel")" "$dir/$rel" -R
    fi
  done <<< "$list"

  printf '%s\n' "$list" > "$state/managed.new"
  mv -f "$state/managed.new" "$state/managed"
  [ ! -e "$state/with-vendor" ] || note='，含第三方 skills'
  say "已安装 $(grep -c '' <<< "$list") 项$note"
}

restore_client() { # restore_client <配置目录>
  local rel
  if [ -f "$1/.agent-kit/managed" ]; then
    while IFS= read -r rel; do restore_entry "$1" "$rel"; done < "$1/.agent-kit/managed"
  fi
  rm -rf -- "$1/.agent-kit"
  echo "→ $1：已恢复原样"
}

if [ "$restore" = 1 ]; then
  found=0
  for client in $clients; do
    dir="$(config_dir "$client")"
    if [ -d "$dir/.agent-kit" ]; then
      restore_client "$dir"
      found=1
    else
      echo "→ $dir：没有安装记录，跳过"
    fi
  done
  [ "$found" = 1 ] || die '没有可恢复的安装记录'
  exit 0
fi

for client in $clients; do install_client "$client"; done
echo '完成，新开会话后生效。恢复原样：./install.sh -r'

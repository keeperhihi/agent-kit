#!/bin/sh
# Install or update Claude Code and Codex to the latest version through their official
# installers, downloading the large release files in parallel ranges so that slow links do not
# run into installer time limits.
# POSIX sh: the official Codex installer is sourced and shares this shell's functions.
set -eu

usage() {
  printf 'Usage: %s --port PORT [claude] [codex]\n' "$0"
  printf 'Install or update Claude Code and Codex (both unless one is named) to the latest version.\n'
  printf '  --port PORT  send every request through the proxy at http://127.0.0.1:PORT (required)\n'
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

# fetch_ranges URL OUTPUT downloads URL in 4 MiB ranges over up to 16 connections. Finished
# ranges stay in the cache until OUTPUT is assembled, so running again resumes the download.
fetch_ranges() (
  url=$1 output=$2 chunk=4194304
  parts="${XDG_CACHE_HOME:-$HOME/.cache}/agent-kit/downloads/$(printf '%s' "$url" | sed 's/[^A-Za-z0-9._-]/_/g')"
  total=$(command curl -q -fsSL --http1.1 --connect-timeout 15 --retry 5 --retry-delay 1 --retry-all-errors \
    -r 0-0 --max-filesize 1 -o /dev/null -D - "$url" |
    awk 'tolower($1) == "content-range:" { split($3, size, "/"); total = size[2] } END { print total + 0 }')
  [ "$total" -gt 0 ] || die "Could not download in ranges: $url"
  mkdir -p "$parts"
  set --
  start=0 ranges=0 cached=0
  while [ "$start" -lt "$total" ]; do
    end=$((start + chunk - 1))
    [ "$end" -lt "$total" ] || end=$((total - 1))
    ranges=$((ranges + 1))
    if [ -f "$parts/$start" ] && [ "$(wc -c < "$parts/$start")" -eq $((end - start + 1)) ]; then
      cached=$((cached + 1))
    else
      [ "$#" -eq 0 ] || set -- "$@" --next
      # HTTP/1.1 keeps each range on its own connection; HTTP/2 would share one.
      set -- "$@" --http1.1 --fail --location --connect-timeout 15 --speed-limit 1024 --speed-time 30 \
        --retry 5 --retry-delay 1 --retry-all-errors -r "$start-$end" -o "$parts/$start" "$url"
    fi
    start=$((end + 1))
  done
  printf 'Downloading %s (%s MiB, %s/%s ranges cached)\n' \
    "${url##*/}" $(((total + 1048575) / 1048576)) "$cached" "$ranges" >&2
  [ "$#" -eq 0 ] || command curl -q --parallel --parallel-max 16 "$@" || :
  start=0
  : > "$output"
  while [ "$start" -lt "$total" ]; do
    end=$((start + chunk - 1))
    [ "$end" -lt "$total" ] || end=$((total - 1))
    [ -f "$parts/$start" ] && [ "$(wc -c < "$parts/$start")" -eq $((end - start + 1)) ] ||
      die "Download incomplete; run again to resume: $url"
    cat "$parts/$start" >> "$output"
    start=$((end + 1))
  done
  rm -rf "$parts"
)

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f 1
}

update_claude() {
  releases=https://downloads.claude.ai/claude-code-releases
  version=$(command curl -q -fsSL --retry 5 --retry-all-errors "$releases/latest")
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die 'Could not read the latest Claude Code version.' ;;
  esac
  current=$("$HOME/.local/bin/claude" --version 2>/dev/null || :)
  if [ "${current%% *}" = "$version" ]; then
    printf 'Claude Code %s is up to date.\n' "$version"
    return
  fi

  # Choose the build the official installer would: native arm64 under Rosetta, musl on musl Linux.
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) die "Unsupported operating system: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
  if [ "$os" = darwin ] && [ "$arch" = x64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    arch=arm64
  fi
  platform=$os-$arch
  if [ "$os" = linux ] && { [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ] ||
    ldd /bin/ls 2>&1 | grep -q musl; }; then
    platform=$platform-musl
  fi

  checksum=$(command curl -q -fsSL --retry 5 --retry-all-errors "$releases/$version/manifest.json" | tr -d ' \n\r\t' |
    sed -n "s/.*\"$platform\":{[^{}]*\"checksum\":\"\([0-9a-f]\{64\}\)\".*/\1/p")
  [ -n "$checksum" ] || die "Claude Code $version has no build for $platform."
  binary="$work/claude-$version"
  printf 'Updating Claude Code to %s\n' "$version"
  # Like the official installer, use the zstd build when zstd is available: about a third of the size.
  if command -v zstd >/dev/null 2>&1; then
    fetch_ranges "$releases/$version/$platform/claude.zst" "$binary.zst"
    zstd -d -q -o "$binary" "$binary.zst"
  else
    fetch_ranges "$releases/$version/$platform/claude" "$binary"
  fi
  [ "$(sha256 "$binary")" = "$checksum" ] || die "Claude Code $version failed checksum verification."
  chmod +x "$binary"
  # The install command copies a running binary of the requested version instead of downloading it.
  "$binary" install "$version"
}

# The official Codex installer downloads its package with curl -o. While it runs in this shell,
# package downloads go to fetch_ranges and every other request to the real curl.
curl() (
  output='' url='' previous=''
  for argument; do
    case "$previous" in -o | --output) output=$argument ;; esac
    case "$argument" in http://* | https://*) url=$argument ;; esac
    previous=$argument
  done
  case "$output:$url" in
    ?*:*.tar.gz | ?*:*.tgz) fetch_ranges "$url" "$output" ;;
    *) command curl -q "$@" ;;
  esac
)

update_codex() {
  command curl -q -fsSL --retry 5 --retry-all-errors -o "$work/codex-install.sh" https://chatgpt.com/codex/install.sh
  printf 'Updating Codex\n'
  (
    CODEX_NON_INTERACTIVE=1
    set -- --release latest
    . "$work/codex-install.sh"
  )
}

clients='' port=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    claude | codex) clients="$clients $1" ;;
    --port)
      case "${2-}" in
        '' | *[!0-9]*) usage >&2; exit 2 ;;
      esac
      [ "$2" -ge 1 ] && [ "$2" -le 65535 ] || { usage >&2; exit 2; }
      port=$2
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$port" ] || { printf 'Missing --port PORT.\n' >&2; usage >&2; exit 2; }
# Send every request through the proxy, including those of the official Codex installer and
# the Claude Code binary. no_proxy and NO_PROXY could exempt hosts from it, so clear them.
proxy="http://127.0.0.1:$port"
export http_proxy="$proxy" https_proxy="$proxy" all_proxy="$proxy" \
  HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" ALL_PROXY="$proxy"
unset no_proxy NO_PROXY
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-kit-update.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for client in ${clients:-claude codex}; do
  "update_$client"
done

#!/usr/bin/env bash
# Exercise update.sh against a local release server: no real downloads or installs.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
root="$(mktemp -d "${TMPDIR:-/tmp}/agent-kit-update-test.XXXXXX")"
server=''
cleanup() {
  [ -z "$server" ] || kill "$server"
  rm -rf "$root"
}
trap cleanup EXIT
checks=0
check() {
  local message="$1"
  shift
  "$@" || { printf 'FAIL: %s\n' "$message" >&2; tail -n 20 "$root/output" >&2; exit 1; }
  checks=$((checks + 1))
}
fails() { ! "$@"; }
www="$root/www"
releases="$www/downloads.claude.ai/claude-code-releases"
mkdir -p "$www" "$root/bin" "$root/home" "$root/tmp"

# Serve $www with Range support; see range_server.py for its request log and fault files.
python3 "$repo/tests/range_server.py" "$www" "$root/port" &
server=$!
while [ ! -s "$root/port" ]; do
  kill -0 "$server"
  sleep 0.1
done
port="$(cat "$root/port")"

# Send every https request to the local server, keeping the host as the first path segment.
cat > "$root/bin/curl" <<SH
#!/bin/sh
for argument; do
  shift
  case "\$argument" in https://*) argument="http://127.0.0.1:$port/\${argument#https://}" ;; esac
  set -- "\$@" "\$argument"
done
exec "$(command -v curl)" "\$@"
SH
chmod +x "$root/bin/curl"
export HOME="$root/home" XDG_CACHE_HOME="$root/cache" TMPDIR="$root/tmp" PATH="$root/bin:$PATH"
unset CLAUDE_CONFIG_DIR CODEX_HOME http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
update() { "$repo/update.sh" "$@" > "$root/output" 2>&1; }
# Usage errors exit with 2, before any request.
rejects() { update "$@"; test "$?" -eq 2; }
requests() { : > "$www/requests.log"; }
# Count range requests for one Claude Code version, leaving out the size probe.
fetched() { grep "^/downloads.claude.ai/claude-code-releases/$1/" "$www/requests.log" | grep -c -v -e ' -$' -e ' bytes=0-0$' || :; }
installed() { test "$("$HOME/.local/bin/claude" --version)" = "$1 (Claude Code)"; }
platforms='darwin-arm64 darwin-x64 linux-arm64 linux-x64 linux-arm64-musl linux-x64-musl'
binary=claude
if command -v zstd > /dev/null; then binary=claude.zst; fi

# Publish a fake Claude Code release for every platform: a 9 MB script that reports its
# version and installs a copy of itself like the native installer.
publish_claude() {
  local version="$1" checksum="$2" platform listing='' build="$root/claude-$1"
  {
    printf '#!/bin/sh\ncase "$1" in\n'
    printf '  --version) echo "%s (Claude Code)" ;;\n' "$version"
    printf '  install) [ "$2" = %s ] || exit 3\n' "$version"
    printf '    mkdir -p "$HOME/.local/share/claude/versions" "$HOME/.local/bin"\n'
    printf '    cp "$0" "$HOME/.local/share/claude/versions/$2"\n'
    printf '    ln -sf "$HOME/.local/share/claude/versions/$2" "$HOME/.local/bin/claude" ;;\n'
    printf 'esac\nexit 0\n'
    head -c 9000000 /dev/urandom
  } > "$build"
  if [ "$checksum" = valid ]; then
    checksum="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$build")"
  fi
  for platform in $platforms; do
    mkdir -p "$releases/$version/$platform"
    cp "$build" "$releases/$version/$platform/claude"
    if command -v zstd > /dev/null; then zstd -q -o "$releases/$version/$platform/claude.zst" "$build"; fi
    listing="$listing${listing:+,}
    \"$platform\": { \"binary\": \"claude\", \"checksum\": \"$checksum\", \"size\": 9000000 }"
  done
  printf '{\n  "version": "%s",\n  "platforms": {%s\n  }\n}\n' "$version" "$listing" > "$releases/$version/manifest.json"
  printf '%s\n' "$version" > "$releases/latest"
}

publish_claude 9.9.9 valid
requests
check 'updates Claude Code' update claude
check 'installs the latest Claude Code' installed 9.9.9
check 'downloads Claude Code in ranges' test "$(fetched 9.9.9)" -ge 2
check 'removes finished ranges' test -z "$(ls -A "$root/cache/agent-kit/downloads")"
check 'removes the work directory' test -z "$(ls -A "$root/tmp")"

requests
check 'runs again when up to date' update claude
check 'reports an up-to-date Claude Code' grep -q 'Claude Code 9.9.9 is up to date.' "$root/output"
check 'skips the download when up to date' test "$(fetched 9.9.9)" -eq 0

publish_claude 9.9.10 valid
for platform in $platforms; do
  echo "/downloads.claude.ai/claude-code-releases/9.9.10/$platform/$binary:4194304"
done > "$www/faults"
check 'fails when a range keeps failing' fails update claude
check 'asks to resume after a failed range' grep -q 'run again to resume' "$root/output"
check 'keeps the installed version after a failed download' installed 9.9.9
rm "$www/faults"
requests
check 'resumes the download' update claude
check 'installs the resumed version' installed 9.9.10
check 'downloads only the missing range' test "$(fetched 9.9.10)" -eq 1

publish_claude 9.9.11 "$(printf '%064d' 0)"
check 'rejects a checksum mismatch' fails update claude
check 'reports the checksum mismatch' grep -q 'failed checksum verification' "$root/output"
check 'does not install an unverified build' installed 9.9.10

# A fake Codex installer that checks what update.sh hands it, reads metadata on stdout and
# downloads its package with a time limit that the slow package server would exceed.
package="$www/releases.openai.com/codex/releases/1.2.3/codex-package-test.tar.gz"
mkdir -p "$(dirname "$package")" "$www/releases.openai.com/codex/channels" "$www/chatgpt.com/codex" "$root/package/bin"
head -c 6000000 /dev/urandom > "$root/package/bin/codex"
tar -czf "$package" -C "$root/package" bin
echo 1.2.3 > "$www/releases.openai.com/codex/channels/latest"
echo /releases.openai.com/codex/releases/1.2.3/codex-package-test.tar.gz > "$www/slow"
cat > "$www/chatgpt.com/codex/install.sh" <<SH
set -eu
[ "\$*" = '--release latest' ] && [ "\$CODEX_NON_INTERACTIVE" = 1 ] || exit 3
[ "\$(curl -fsSL https://releases.openai.com/codex/channels/latest)" = 1.2.3 ] || exit 4
url=https://releases.openai.com/codex/releases/1.2.3/codex-package-test.tar.gz
output="\$(mktemp -d)/package.tar.gz"
argument=installer previous=installer start=installer total=installer parts=installer
saved="\$url \$output \$argument \$previous \$start \$total \$parts"
curl -fsSL --connect-timeout 10 --max-time 1 "\$url" -o "\$output"
[ "\$url \$output \$argument \$previous \$start \$total \$parts" = "\$saved" ] || exit 5
cmp -s "\$output" "$package" || exit 6
mkdir -p "\$HOME/.codex" && tar -xzf "\$output" -C "\$HOME/.codex"
echo 'Codex CLI 1.2.3 installed successfully.'
SH
requests
check 'runs the Codex installer' update codex
check 'installs the Codex package' cmp -s "$HOME/.codex/bin/codex" "$root/package/bin/codex"
check 'downloads the Codex package in ranges' test "$(grep -c 'codex-package-test.tar.gz bytes=[1-9]' "$www/requests.log")" -ge 1

# --proxy sends every request through the release server, which also serves as a proxy.
publish_claude 9.9.12 valid
requests
check 'updates through --proxy' update --proxy "$port"
check 'installs through the proxy' installed 9.9.12
check 'sends every request through the proxy' test -z "$(grep -v ' via proxy$' "$www/requests.log")"

# Without --proxy, requests go directly even when proxy variables point elsewhere.
publish_claude 9.9.13 valid
requests
unreachable=http://127.0.0.1:9
export http_proxy=$unreachable https_proxy=$unreachable all_proxy=$unreachable \
  HTTP_PROXY=$unreachable HTTPS_PROXY=$unreachable ALL_PROXY=$unreachable
check 'ignores proxy variables without --proxy' update
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
check 'installs without a proxy' installed 9.9.13
check 'sends no request through a proxy' test -z "$(grep ' via proxy$' "$www/requests.log")"

for arguments in nope --proxy '--proxy 7897x' '--proxy 0' '--proxy 65536'; do
  check "rejects $arguments" rejects $arguments
done
printf 'PASS: %s checks through update.sh\n' "$checks"

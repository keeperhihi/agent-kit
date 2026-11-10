#!/usr/bin/env bash
# Exercise the public installer in temporary repositories and client directories.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python="$repo/.venv/bin/python"
[ -x "$python" ] || python=python3
exec "$python" "$repo/tests/preferences.py"

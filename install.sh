#!/usr/bin/env bash
# Apply personal preferences without replacing client configuration.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
python="$repo/.venv/bin/python"
if [ ! -x "$python" ]; then
  command -v python3 >/dev/null 2>&1 || { printf 'Python 3.9 or newer is required.\n' >&2; exit 1; }
  python3 -c 'import sys; sys.exit("Python 3.9 or newer is required.") if sys.version_info < (3, 9) else None'
  printf 'Creating environment: %s\n' "$repo/.venv"
  python3 -m venv "$repo/.venv"
fi

required="$(sed -n 's/^tomlkit==//p' "$repo/requirements.txt")"
if ! "$python" -c 'import importlib.util, importlib.metadata, sys; sys.exit(importlib.util.find_spec("tomlkit") is None or importlib.metadata.version("tomlkit") != sys.argv[1])' "$required"; then
  printf 'Installing dependencies in %s\n' "$repo/.venv"
  "$python" -m pip install --disable-pip-version-check -r "$repo/requirements.txt"
fi
exec "$python" "$repo/preferences.py" "$@"

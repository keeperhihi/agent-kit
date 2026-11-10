#!/usr/bin/env python3
"""Apply and restore only the preference fields supplied by this repository."""

import argparse
import copy
import json
import os
from pathlib import Path
import sys
import tempfile

try:
    import tomlkit
except ImportError:
    sys.exit("Run install.sh (or install.ps1 on Windows) to prepare the Python environment.")


REPO = Path(__file__).resolve().parent
FILES = {
    "claude": ("settings.json", "plugins/claude-hud/config.json"),
    "codex": ("config.toml",),
}
STATE = Path(".agent-kit/preferences.json")
MISSING = object()


def plain(value):
    return value.unwrap() if hasattr(value, "unwrap") else copy.deepcopy(value)


def parse(text, kind):
    value = tomlkit.parse(text) if kind == "toml" else json.loads(text)
    if not isinstance(value, dict):
        raise ValueError("configuration must be an object")
    return value


def dump(value, kind):
    if kind == "toml":
        return tomlkit.dumps(value)
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def packed(value, kind):
    if value is MISSING:
        return {"exists": False}
    value = plain(value)
    # TOML values can include dates and times, which JSON cannot store.
    return {"exists": True, "value": dump({"value": value}, kind)}


def unpacked(record, kind):
    if not record["exists"]:
        return MISSING
    return plain(parse(record["value"], kind)["value"])


def leaves(value, prefix=()):
    for key, child in value.items():
        path = prefix + (key,)
        if isinstance(child, dict):
            yield from leaves(child, path)
        else:
            yield path, plain(child)


def get(document, path):
    node = document
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return MISSING
        node = node[key]
    return node


def put(document, path, value, created):
    node = document
    for depth, key in enumerate(path[:-1], 1):
        if key not in node:
            node[key] = {}
            parent = list(path[:depth])
            if parent not in created:
                created.append(parent)
        if not isinstance(node[key], dict):
            raise ValueError("cannot merge an object into " + ".".join(path[:depth]))
        node = node[key]
    node[path[-1]] = value


def remove(document, path):
    parent = get(document, path[:-1]) if len(path) > 1 else document
    if isinstance(parent, dict):
        parent.pop(path[-1], None)


def prune(document, created):
    remaining = []
    for path in sorted(created, key=len, reverse=True):
        node = get(document, path)
        if isinstance(node, dict) and not node:
            remove(document, path)
        elif node is not MISSING:
            remaining.append(path)
    return remaining


def regular(path):
    # Replacing a symlink would silently detach someone else's configuration.
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError("expected a regular file: " + str(path))
    for parent in path.parents:
        if parent.is_symlink():
            raise ValueError("configuration parent is a symlink: " + str(parent))
        if parent.exists() and not parent.is_dir():
            raise ValueError("configuration parent is not a directory: " + str(parent))


def read_document(path, kind):
    regular(path)
    if not path.exists():
        return tomlkit.document() if kind == "toml" else {}
    try:
        return parse(path.read_text(encoding="utf-8"), kind)
    except Exception as error:
        # Parser messages may echo credentials from the live file.
        raise ValueError("invalid " + kind.upper() + " in " + str(path)) from error


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".agent-kit.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def restore_field(document, entry, kind):
    path = entry["path"]
    # Leave edits made by the client or another tool after our last application.
    applied = [entry["applied"]] + entry.get("previous", [])
    if packed(get(document, path), kind) not in applied:
        return
    original = unpacked(entry["original"], kind)
    if original is MISSING:
        remove(document, path)
    else:
        put(document, path, original, [])


def plan(client, directory, restore):
    state_path = directory / STATE
    state = read_document(state_path, "json")
    if state and state.get("version") != 1:
        raise ValueError("unsupported preference record: " + str(state_path))
    if restore and not state:
        return None
    records = state.get("files", {})
    if any(relative not in FILES[client] for relative in records):
        raise ValueError("unexpected file in preference record: " + str(state_path))

    changes = []
    new_records = {}
    pending_records = copy.deepcopy(records)
    for relative in FILES[client]:
        target = directory / relative
        kind = "toml" if target.suffix == ".toml" else "json"
        source = REPO / client / relative
        old = records.get(relative)
        if restore and old is None:
            continue
        if not restore and not source.exists() and old is None:
            continue
        document = read_document(target, kind)
        before = dump(document, kind)
        old = copy.deepcopy(old) if old else {
            "existed": target.exists(), "created": [], "fields": []
        }
        entries = {tuple(entry["path"]): entry for entry in old["fields"]}
        patch = {} if restore or not source.exists() else read_document(source, kind)
        desired = dict(leaves(patch))

        for path in list(entries):
            if path not in desired:
                restore_field(document, entries.pop(path), kind)
        old["created"] = prune(document, old["created"])

        for path, value in desired.items():
            if path not in entries:
                entries[path] = {
                    "path": list(path), "original": packed(get(document, path), kind)
                }
            put(document, path, value, old["created"])
            applied = packed(get(document, path), kind)
            previous = entries[path].get("applied")
            if previous is not None and previous != applied:
                candidates = entries[path].setdefault("previous", [])
                if previous not in candidates:
                    candidates.append(previous)
            entries[path]["applied"] = applied

        # A failed write must retain both the old and intended applied values,
        # and fields being released, until the live files have been written.
        pending = copy.deepcopy(old)
        pending_fields = {
            tuple(entry["path"]): entry
            for entry in pending_records.get(relative, {}).get("fields", [])
        }
        pending_fields.update(copy.deepcopy(entries))
        pending["fields"] = list(pending_fields.values())
        for parent in pending_records.get(relative, {}).get("created", []):
            if parent not in pending["created"]:
                pending["created"].append(parent)
        pending_records[relative] = pending

        after = dump(document, kind)
        if not entries and not old["existed"] and not document and (kind == "json" or not after.strip()):
            changes.append((target, None))
        elif after != before or (entries and not target.exists()):
            changes.append((target, after))
        if entries:
            for entry in entries.values():
                entry.pop("previous", None)
            old["fields"] = list(entries.values())
            new_records[relative] = old

    next_state = {"version": 1, "files": new_records}
    pending_state = {"version": 1, "files": pending_records}
    return client, state_path, next_state, pending_state, changes


def apply(prepared, restore):
    client, state_path, next_state, pending_state, changes = prepared
    if not restore:
        # Save originals before changing preferences, including partial installs.
        atomic_write(state_path, dump(pending_state, "json"))
    for path, text in changes:
        if text is None:
            path.unlink(missing_ok=True)
        else:
            atomic_write(path, text)
        print("  " + str(path))
    if restore:
        state_path.unlink()
        if not any(state_path.parent.iterdir()):
            state_path.parent.rmdir()
    else:
        atomic_write(state_path, dump(next_state, "json"))
    print(("Restored " if restore else "Applied ") + client + " preferences")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("clients", nargs="*", metavar="{claude,codex}")
    parser.add_argument("-r", "--restore", action="store_true")
    args = parser.parse_args()
    if any(client not in FILES for client in args.clients):
        parser.error("clients must be claude or codex")
    clients = list(dict.fromkeys(args.clients or FILES))
    directories = {
        "claude": Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude").resolve(),
        "codex": Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").resolve(),
    }
    # Parse all selected clients before writing any of their files.
    prepared = [plan(client, directories[client], args.restore) for client in clients]
    if args.restore and not any(prepared):
        raise ValueError("no preference record; old whole-file backups are not restored")
    for item in prepared:
        if item is not None:
            apply(item, args.restore)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit("Error: " + str(error))

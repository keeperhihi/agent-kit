#!/usr/bin/env python3
"""Install client preferences and resources, optionally using a gateway integration."""

import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
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
RESOURCE_STATE = Path(".agent-kit/resources.json")
RESOURCE_BACKUPS = Path(".agent-kit/resource-backups")
INSTRUCTIONS = {"claude": "CLAUDE.md", "codex": "AGENTS.md"}
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
    regular_parents(path)


def regular_parents(path):
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


def plan(client, directory, restore, overrides=None):
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
        extra = (overrides or {}).get(relative, {}) if not restore else {}
        old = records.get(relative)
        if restore and old is None:
            continue
        if not restore and not source.exists() and old is None and not extra:
            continue
        document = read_document(target, kind)
        before = dump(document, kind)
        old = copy.deepcopy(old) if old else {
            "existed": target.exists(), "created": [], "fields": []
        }
        entries = {tuple(entry["path"]): entry for entry in old["fields"]}
        patch = {} if restore or not source.exists() else read_document(source, kind)
        desired = dict(leaves(patch))
        additions = dict(extra.get("set", {}))
        additions.update({tuple(path): MISSING for path in extra.get("remove", [])})
        for path, value in additions.items():
            # A gateway can own a whole provider table, replacing its base
            # patch's individual fields without recording overlapping owners.
            for existing in list(desired):
                if existing[:len(path)] == path or path[:len(existing)] == existing:
                    del desired[existing]
            desired[path] = value

        for path in list(entries):
            if path not in desired:
                restore_field(document, entries.pop(path), kind)
        old["created"] = prune(document, old["created"])

        for path, value in desired.items():
            if path not in entries:
                entries[path] = {
                    "path": list(path), "original": packed(get(document, path), kind)
                }
            if value is MISSING:
                remove(document, path)
            else:
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


def resource_sources(client):
    instructions = REPO / "instructions.md"
    if not instructions.is_file():
        raise ValueError("missing instructions: " + str(instructions))
    sources = {INSTRUCTIONS[client]: instructions}
    for folder in [REPO / "skills", REPO / "vendor/skills"]:
        if not folder.is_dir():
            continue
        for skill in sorted(folder.iterdir()):
            if skill.name.startswith(".") or not (skill / "SKILL.md").is_file():
                continue
            relative = "skills/" + skill.name
            if relative in sources:
                raise ValueError("duplicate skill name: " + skill.name)
            sources[relative] = skill
    return sources


def resource_link(path, entry):
    return path.is_symlink() and os.readlink(path) in [entry["source"], *entry.get("previous", [])]


def plan_resources(client, directory, restore):
    state_path = directory / RESOURCE_STATE
    state = read_document(state_path, "json")
    if state and state.get("version") != 1:
        raise ValueError("unsupported resource record: " + str(state_path))
    if restore and not state:
        return None
    records = copy.deepcopy(state.get("links", {}))
    desired = {} if restore else resource_sources(client)
    for relative in records:
        parts = relative.split("/")
        if relative != INSTRUCTIONS[client] and not (
                len(parts) == 2 and parts[0] == "skills" and parts[1] not in ["", ".", ".."]
                and "\\" not in parts[1]):
            raise ValueError("unexpected resource in record: " + str(state_path))

    for relative in dict.fromkeys([*records, *desired]):
        target = directory / relative
        saved = directory / RESOURCE_BACKUPS / relative
        regular_parents(target)
        regular_parents(saved)
        old = records.get(relative)
        source = desired.get(relative)
        exists = target.exists() or target.is_symlink()
        if old is None:
            if saved.exists() or saved.is_symlink():
                raise ValueError("resource backup already exists: " + str(saved))
            # Whatever is there, a copy, local edits or a link elsewhere, moves to the backup as it is.
            old = {"source": str(source), "original": exists}
            records[relative] = old
        elif source is not None and exists and not resource_link(target, old):
            # Resume an interrupted first install before the original was moved.
            if not (old["original"] and not saved.exists() and not saved.is_symlink()):
                raise ValueError("resource was replaced; keep or merge it first: " + str(target))
        if source is not None and old["source"] != str(source):
            old.setdefault("previous", []).append(old["source"])
            old["source"] = str(source)
    return client, directory, records, desired


def discard_resource(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def apply_resources(prepared, restore):
    client, directory, records, desired = prepared
    state_path = directory / RESOURCE_STATE
    backups = directory / RESOURCE_BACKUPS
    # Keep ownership and the original's presence before moving any live path.
    # Previous link destinations let rollback recover an interrupted relink.
    if not restore:
        atomic_write(state_path, dump({"version": 1, "links": records}, "json"))
    for relative, entry in list(records.items()):
        target = directory / relative
        saved = backups / relative
        source = desired.get(relative)
        if source is None:
            if resource_link(target, entry):
                target.unlink()
            # A file or link the user put there afterwards stays in place.
            if not target.exists() and not target.is_symlink() and (saved.exists() or saved.is_symlink()):
                target.parent.mkdir(parents=True, exist_ok=True)
                saved.rename(target)
            else:
                discard_resource(saved)
            del records[relative]
        else:
            if entry["original"] and not saved.exists() and not saved.is_symlink():
                saved.parent.mkdir(parents=True, exist_ok=True)
                target.rename(saved)
            if target.is_symlink() and os.readlink(target) == str(source):
                continue
            if (target.exists() or target.is_symlink()) and not resource_link(target, entry):
                raise ValueError("resource changed during installation: " + str(target))
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".agent-kit.", dir=target.parent) as temporary:
                link = Path(temporary) / "link"
                link.symlink_to(source, target_is_directory=source.is_dir())
                os.replace(link, target)
        print("  " + str(target))
    if records:
        for entry in records.values():
            entry.pop("previous", None)
        atomic_write(state_path, dump({"version": 1, "links": records}, "json"))
    else:
        state_path.unlink(missing_ok=True)
    for path in [backups / "skills", backups, state_path.parent]:
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()
    print(("Restored " if restore else "Linked ") + client + " resources")


def main():
    os.umask(0o077)
    gateways = sorted(path.parent.name for path in (REPO / "gateways").glob("*/gateway.json"))
    selection = argparse.ArgumentParser(add_help=False)
    selection.add_argument("--gateway", "-gateway", choices=gateways,
                           help="use this gateway's integration; default installs resources directly")
    selected, _ = selection.parse_known_args()
    parser = argparse.ArgumentParser(description=__doc__, parents=[selection])
    parser.add_argument("clients", nargs="*", metavar="{claude,codex}")
    parser.add_argument("-r", "--restore", action="store_true")
    adapter = None
    if selected.gateway:
        adapter_path = REPO / "gateways" / selected.gateway / "adapter.py"
        if adapter_path.is_file():
            spec = importlib.util.spec_from_file_location("agent_kit_gateway", adapter_path)
            adapter = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(adapter)
            adapter.add_arguments(parser)
    args, unknown = parser.parse_known_args()
    if unknown:
        # Unknown gateway options may carry credentials; do not echo values.
        parser.error("unrecognized arguments; see --help for this gateway")
    if any(client not in FILES for client in args.clients):
        parser.error("clients must be claude or codex")
    clients = list(dict.fromkeys(args.clients or FILES))
    directories = {
        "claude": Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude").resolve(),
        "codex": Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").resolve(),
    }
    for client in clients:
        for state in (directories[client] / ".agent-kit/gateways").glob("*.json"):
            regular(state)
            if state.stem != args.gateway:
                raise ValueError("restore gateway " + state.stem + " before selecting another installation mode")
    gateway = None
    link_resources = True
    if args.gateway:
        gateway_dir = REPO / "gateways" / args.gateway
        gateway = read_document(gateway_dir / "gateway.json", "json")
        if gateway.get("resources") not in ["native", "gateway"]:
            raise ValueError("unknown resource ownership in " + str(gateway_dir / "gateway.json"))
        link_resources = gateway["resources"] == "native"
        if not link_resources and not args.restore:
            for client in clients:
                state = read_document(directories[client] / RESOURCE_STATE, "json")
                if state.get("links"):
                    raise ValueError("restore agent-kit resources before handing them to the gateway: "
                                     + str(directories[client]))
    overrides, gateway_plan = ({}, None) if adapter is None else adapter.prepare(
        args, clients, directories, read_document)
    # Prepare every configuration, resource and credential change before writing.
    prepared = [plan(client, directories[client], args.restore, overrides.get(client)) for client in clients]
    resources = ([plan_resources(client, directories[client], args.restore) for client in clients]
                 if link_resources else [])
    if args.restore and not any([*prepared, *resources, gateway_plan]):
        raise ValueError("no installation record; old whole-file backups are not restored")
    if gateway_plan is not None and not args.restore:
        adapter.apply(gateway_plan, atomic_write)
    for item in prepared:
        if item is not None:
            apply(item, args.restore)
    for item in resources:
        if item is not None:
            apply_resources(item, args.restore)
    if gateway_plan is not None and args.restore:
        adapter.apply(gateway_plan, atomic_write)
    if gateway is not None and not args.restore:
        print("Gateway integration: " + gateway["name"])
        if not link_resources:
            print("  Instructions and skills are managed by the gateway.")
        print("  Setup: " + str(gateway_dir / "README.md"))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit("Error: " + str(error))

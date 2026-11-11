"""CodexManager's provider settings and reversible API-key login."""

import copy
import json
import os
from pathlib import Path
import stat


STATE = Path(".agent-kit/gateways/codexmanager.json")


def add_arguments(parser):
    parser.add_argument("--cm-key", metavar="KEY",
                        help="CodexManager key; otherwise use CODEXMANAGER_API_KEY or the existing CM login")


def prepare(args, clients, directories, read_document):
    if "codex" not in clients:
        raise ValueError("CodexManager requires the codex client")
    if args.restore and args.cm_key is not None:
        raise ValueError("--cm-key cannot be used with --restore")
    directory = directories["codex"]
    auth_path = directory / "auth.json"
    state_path = directory / STATE
    record = read_document(state_path, "json")
    if record and record.get("version") != 1:
        raise ValueError("unsupported CodexManager login record: " + str(state_path))
    if args.restore and not record:
        return {}, None
    current = read_document(auth_path, "json")
    if args.restore:
        return {}, (state_path, auth_path, record, current, True)

    config = read_document(directory / "config.toml", "toml")
    template = read_document(Path(__file__).with_name("codex.toml"), "toml")
    profile = config.get("profile")
    profile_config = config.get("profiles", {}).get(profile, {}) if profile else {}
    provider = profile_config.get("model_provider", config.get("model_provider", "openai"))
    provider_config = config.get("model_providers", {}).get(provider, {})
    store = profile_config.get("cli_auth_credentials_store", config.get("cli_auth_credentials_store", "auto"))
    own_login = (provider == "cm" and store == "file"
                 and provider_config.get("base_url") == template["model_providers"]["cm"]["base_url"]
                 and provider_config.get("requires_openai_auth") is True
                 and not any(provider_config.get(key) for key in ["env_key", "auth", "experimental_bearer_token"]))
    key = args.cm_key if args.cm_key is not None else os.environ.get("CODEXMANAGER_API_KEY")
    if key is None and own_login and current.get("auth_mode") == "apikey":
        key = current.get("OPENAI_API_KEY")
    if not isinstance(key, str) or not key.strip():
        raise ValueError("provide --cm-key or CODEXMANAGER_API_KEY; an existing CodexManager API-key login can also be reused")
    applied = {"auth_mode": "apikey", "OPENAI_API_KEY": key.strip()}
    if not record:
        record = {"version": 1, "original": {
            "text": auth_path.read_bytes().decode("utf-8") if auth_path.exists() else None,
            "mode": stat.S_IMODE(auth_path.stat().st_mode) if auth_path.exists() else 0o600,
        }}
    else:
        record = copy.deepcopy(record)
    previous = record.get("applied")
    if previous is not None and previous != applied:
        candidates = record.setdefault("previous", [])
        if previous not in candidates:
            candidates.append(previous)
    record["applied"] = applied

    fields = {
        ("model_provider",): template["model_provider"],
        ("cli_auth_credentials_store",): template["cli_auth_credentials_store"],
        ("model_providers", "cm"): template["model_providers"]["cm"].unwrap(),
    }
    removed = [("model_catalog_json",), ("openai_base_url",)]
    if profile:
        fields[("profiles", profile, "model_provider")] = template["model_provider"]
        removed += [("profiles", profile, name) for name in
                    ["model_catalog_json", "openai_base_url", "cli_auth_credentials_store"]]
    overrides = {"codex": {"config.toml": {"set": fields, "remove": removed}}}
    return overrides, (state_path, auth_path, record, current, False)


def apply(prepared, atomic_write):
    state_path, auth_path, record, current, restore = prepared
    if restore:
        if current in [record["applied"], *record.get("previous", [])]:
            original = record["original"]
            if original["text"] is None:
                auth_path.unlink(missing_ok=True)
            else:
                atomic_write(auth_path, original["text"])
                auth_path.chmod(original["mode"])
            print("Restored Codex login")
        else:
            print("Kept the current Codex login")
        state_path.unlink()
        for parent in [state_path.parent, state_path.parent.parent]:
            if parent.is_dir() and not any(parent.iterdir()):
                parent.rmdir()
        return

    # Preserve the first login before replacing auth.json. Keep prior applied
    # keys until the new write succeeds so a failed rotation can be rolled back.
    atomic_write(state_path, json.dumps(record, indent=2) + "\n")
    atomic_write(auth_path, json.dumps(record["applied"], indent=2) + "\n")
    record.pop("previous", None)
    atomic_write(state_path, json.dumps(record, indent=2) + "\n")
    print("Configured CodexManager credentials")

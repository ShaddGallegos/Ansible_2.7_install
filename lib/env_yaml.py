#!/usr/bin/env python3
"""Vault-encrypted, multi-project key/value store for installer state.

Canonical file: ~/.ansible/conf/env.yml (Ansible Vault encrypted)
Canonical vault password file: ~/.ansible/conf/.vaultpass.txt (never recreated
if it already exists)

This file is the single source of truth for ALL local Ansible/GIT projects,
not just this one. To avoid cross-project key collisions it is organized as:

  common:
    KEY: value          # shared by any project (RHSM/CDN/registry creds, etc.)
  <project-name>:
    KEY: value           # project-specific; overrides "common" on collision

This helper is invoked by lib/state.sh; it is not meant to be run directly.
"""
import base64
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML is required to read/write env.yml (pip install pyyaml)\n")
    sys.exit(1)

try:
    from ansible.parsing.vault import VaultLib, VaultSecret
except ImportError:
    VaultLib = None
    VaultSecret = None


def _read_vault_password(vault_pass_file):
    if not os.path.exists(vault_pass_file):
        os.makedirs(os.path.dirname(vault_pass_file), exist_ok=True)
        with open(vault_pass_file, "wb") as fh:
            fh.write(base64.b64encode(os.urandom(32)))
        os.chmod(vault_pass_file, 0o600)
    with open(vault_pass_file, "rb") as fh:
        return fh.read().strip()


def _vaultlib(vault_pass_file):
    if VaultLib is None:
        sys.stderr.write("The 'ansible' package is required to read/write vault-encrypted env.yml\n")
        sys.exit(1)
    return VaultLib([("default", VaultSecret(_read_vault_password(vault_pass_file)))])


def load(path, vault_pass_file):
    if not os.path.exists(path):
        return {}
    with open(path, "rb") as fh:
        raw = fh.read()
    if not raw.strip():
        return {}
    if raw.lstrip().startswith(b"$ANSIBLE_VAULT"):
        raw = _vaultlib(vault_pass_file).decrypt(raw)
    data = yaml.safe_load(raw)
    return data if isinstance(data, dict) else {}


def dump(path, data, vault_pass_file):
    plaintext = yaml.safe_dump(data, default_flow_style=False, sort_keys=True).encode("utf-8")
    encrypted = _vaultlib(vault_pass_file).encrypt(plaintext)
    if isinstance(encrypted, str):
        encrypted = encrypted.encode("utf-8")
    tmp = "{0}.tmp.{1}".format(path, os.getpid())
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "wb") as fh:
        fh.write(encrypted)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def ensure_structure(path, vault_pass_file, project):
    """Move any legacy flat (non-namespaced) top-level keys into the
    project section, and guarantee 'common' and the project section exist.
    Idempotent: a no-op once the file is already namespaced."""
    data = load(path, vault_pass_file)
    common = data.get("common")
    project_data = data.get(project)
    common = common if isinstance(common, dict) else {}
    project_data = project_data if isinstance(project_data, dict) else {}

    changed = "common" not in data or project not in data
    for key in list(data.keys()):
        if key in ("common", project):
            continue
        project_data[key] = data.pop(key)
        changed = True

    if changed:
        data["common"] = common
        data[project] = project_data
        dump(path, data, vault_pass_file)


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(
            "usage: env_yaml.py <dump-b64|set|delete|ensure-structure> <path> "
            "<vault_pass_file> <project> [key] [value]\n"
        )
        sys.exit(2)

    mode, path, vault_pass_file, project = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

    if mode == "ensure-structure":
        ensure_structure(path, vault_pass_file, project)
        return

    data = load(path, vault_pass_file)

    if mode == "dump-b64":
        common = data.get("common") or {}
        project_data = data.get(project) or {}
        merged = dict(common)
        merged.update(project_data)
        for key, value in merged.items():
            if value is None:
                continue
            encoded = base64.b64encode(str(value).encode("utf-8")).decode("ascii")
            print("{0}_B64={1}".format(key, encoded))
    elif mode == "set":
        key, value = sys.argv[5], sys.argv[6]
        section = data.get(project)
        section = section if isinstance(section, dict) else {}
        section[key] = value
        data[project] = section
        dump(path, data, vault_pass_file)
    elif mode == "delete":
        key = sys.argv[5]
        section = data.get(project)
        if isinstance(section, dict) and key in section:
            section.pop(key, None)
            data[project] = section
            dump(path, data, vault_pass_file)
    else:
        sys.stderr.write("Unknown mode: {0}\n".format(mode))
        sys.exit(2)


if __name__ == "__main__":
    main()


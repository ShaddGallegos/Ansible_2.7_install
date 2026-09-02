import os
import shutil
import subprocess
import sys
import tempfile

import yaml

def load_vault(env_file, vault_pass):
    if not os.path.exists(env_file) or os.path.getsize(env_file) == 0:
        return {}
    with open(env_file, "rb") as stream:
        encrypted = stream.read(14) == b"$ANSIBLE_VAULT"

    if encrypted:
        res = subprocess.run(
            ["ansible-vault", "view", env_file, "--vault-password-file", vault_pass],
            capture_output=True, text=True, check=True
        )
        data = yaml.safe_load(res.stdout)
        return data if isinstance(data, dict) else {}

    with open(env_file, "r", encoding="utf-8") as stream:
        data = yaml.safe_load(stream)
        return data if isinstance(data, dict) else {}

def save_vault(env_file, vault_pass, data):
    yaml_text = yaml.dump(data, default_flow_style=False)
    env_dir = os.path.dirname(os.path.abspath(env_file))
    os.makedirs(env_dir, mode=0o700, exist_ok=True)
    file_descriptor, temporary_path = tempfile.mkstemp(prefix=".env.yml.", dir=env_dir)
    os.close(file_descriptor)
    try:
        subprocess.run(
            ["ansible-vault", "encrypt", "--vault-password-file", vault_pass, "--output", temporary_path],
            input=yaml_text, text=True, capture_output=True, check=True
        )
        os.chmod(temporary_path, 0o600)
        if os.path.exists(env_file) and os.path.getsize(env_file) > 0:
            backup_path = f"{env_file}.bak"
            shutil.copy2(env_file, backup_path)
            os.chmod(backup_path, 0o600)
        os.replace(temporary_path, env_file)
    except Exception as exc:
        raise RuntimeError(f"Unable to encrypt {env_file} with Ansible Vault") from exc
    finally:
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)

def clean_dict(d):
    if not isinstance(d, dict):
        return {}
    res = {}
    for k, v in d.items():
        k_upper = str(k).upper() if isinstance(k, str) else k
        if k_upper not in res or (not res[k_upper] and v):
            res[k_upper] = v
    return res

def project_key_variants(proj_key):
    keys = []
    if proj_key is None:
        return keys
    for candidate in [proj_key, str(proj_key).upper(), str(proj_key).lower()]:
        if candidate not in keys:
            keys.append(candidate)
    return keys


def find_project_mapping(data, proj_key):
    if not isinstance(data, dict):
        return None
    normalized = str(proj_key).upper()
    for key, value in data.items():
        if str(key).upper() == normalized and isinstance(value, dict):
            return value
    return None


def merge_missing(target, defaults):
    changed = False
    for key, value in defaults.items():
        if key not in target:
            target[key] = value
            changed = True
        elif isinstance(target[key], dict) and isinstance(value, dict):
            changed = merge_missing(target[key], value) or changed
    return changed


def normalize_project_keys(project_data):
    changed = False
    for key in list(project_data):
        uppercase_key = str(key).upper()
        if key == uppercase_key:
            continue
        value = project_data[key]
        if project_data.get(uppercase_key) in (None, "") and value not in (None, ""):
            project_data[uppercase_key] = value
        del project_data[key]
        changed = True
    return changed


def main():
    if len(sys.argv) < 2:
        sys.exit(0)

    mode = sys.argv[1]

    if mode == "get-value" and len(sys.argv) >= 6:
        env_file, vault_pass, proj_key, key = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        data = clean_dict(load_vault(env_file, vault_pass))
        key_upper = key.upper()
        variants = project_key_variants(proj_key)

        val = ""
        for project_name in variants:
            if project_name in data and isinstance(data[project_name], dict):
                sub = clean_dict(data[project_name])
                val = sub.get(key_upper, "")
                if val:
                    break

        if not val:
            val = data.get(key_upper, "")
            if not val:
                for project_name in variants:
                    if project_name in data and isinstance(data[project_name], dict):
                        sub = clean_dict(data[project_name])
                        val = sub.get(key, "")
                        if val:
                            break

        if val is not None and val != "":
            print(val)

    elif mode == "set" and len(sys.argv) >= 7:
        env_file, vault_pass, proj_key, key, val = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
        data = clean_dict(load_vault(env_file, vault_pass))
        key_upper = key.upper()
        project_name = str(proj_key).upper()

        if project_name not in data or not isinstance(data[project_name], dict):
            data[project_name] = {}

        data[key_upper] = val
        sub = clean_dict(data[project_name])
        sub[key_upper] = val
        data[project_name] = sub

        if proj_key not in data:
            data[proj_key] = sub

        save_vault(env_file, vault_pass, data)

    elif mode == "ensure-structure" and len(sys.argv) >= 5:
        env_file, vault_pass, proj_key = sys.argv[2], sys.argv[3], sys.argv[4]
        data = clean_dict(load_vault(env_file, vault_pass))
        project_name = str(proj_key).upper()
        if project_name not in data or not isinstance(data[project_name], dict):
            data[project_name] = {}
        save_vault(env_file, vault_pass, data)

    elif mode == "ensure-schema" and len(sys.argv) >= 6:
        env_file, vault_pass, proj_key, template_file = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        data = load_vault(env_file, vault_pass)
        with open(template_file, "r", encoding="utf-8") as stream:
            template_data = yaml.safe_load(stream) or {}

        template_project = find_project_mapping(template_data, proj_key)
        if template_project is None:
            template_project = find_project_mapping(template_data, "ANSIBLE_2.7_INSTALL")
        if template_project is None:
            raise KeyError(f"Project section {proj_key} is missing from {template_file}")

        project_name = str(proj_key).upper()
        project_data = data.get(project_name)
        if not isinstance(project_data, dict):
            project_data = {}
            data[project_name] = project_data

        changed = False
        for existing_name, existing_data in list(data.items()):
            if (str(existing_name).upper() == project_name
                    and isinstance(existing_data, dict)
                    and existing_data is not project_data):
                for key, value in existing_data.items():
                    if project_data.get(key) in (None, "") and value not in (None, ""):
                        project_data[key] = value
                        changed = True

        for key in template_project:
            if project_data.get(key) in (None, "") and data.get(key) not in (None, ""):
                project_data[key] = data[key]
                changed = True

        changed = normalize_project_keys(project_data) or changed
        changed = merge_missing(project_data, template_project) or changed
        if changed:
            save_vault(env_file, vault_pass, data)

    elif mode == "missing-keys" and len(sys.argv) >= 6:
        env_file, vault_pass, proj_key, template_file = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        data = load_vault(env_file, vault_pass)
        with open(template_file, "r", encoding="utf-8") as stream:
            template_data = yaml.safe_load(stream) or {}
        project_data = find_project_mapping(data, proj_key) or {}
        template_project = (find_project_mapping(template_data, proj_key)
                    or find_project_mapping(template_data, "ANSIBLE_2.7_INSTALL")
                    or {})
        for key in sorted(set(template_project) - set(project_data)):
            print(key)

if __name__ == "__main__":
    main()

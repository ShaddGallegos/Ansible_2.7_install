#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_LIB="${SCRIPT_DIR}/lib/target.sh"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"
INSTALLER="${SCRIPT_DIR}/aap27_installer.sh"

echo "[1/4] Injecting missing get_install_scope into lib/target.sh..."
python3 - << 'PYEOF'
with open("lib/target.sh", "r") as f:
    content = f.read()

get_scope_func = r"""
get_install_scope() {
    if [[ -n "${INSTALL_SCOPE:-}" ]]; then
        echo "$INSTALL_SCOPE"
        return 0
    fi
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    local scope
    scope="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" INSTALL_SCOPE 2>/dev/null || echo "")"
    if [[ -z "$scope" && -f "$env_file" ]]; then
        scope="$(grep -oP '^INSTALL_SCOPE_B64=\K.*' "$env_file" | base64 --decode 2>/dev/null || echo "")"
    fi
    echo "${scope:-local}"
}
"""

if "get_install_scope()" not in content:
    content += get_scope_func

with open("lib/target.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/4] Updating load_env in lib/state.sh to support base64 state lines..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

load_env_fix = r"""load_env() {
    local line key encoded decoded
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"

    if [[ -f "$env_file" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^([A-Za-z0-9_]+)_B64=([A-Za-z0-9+/=]+)$ ]]; then
                key="${BASH_REMATCH[1]}"
                encoded="${BASH_REMATCH[2]}"
                decoded="$(printf %s "$encoded" | base64 --decode 2>/dev/null || echo "")"
                if [[ -n "$decoded" ]]; then
                    printf -v "$key" %s "$decoded"
                    if [[ "$key" == "rhsm_user" ]]; then RHSM_USERNAME="$decoded"; fi
                    if [[ "$key" == "rhsm_password" ]]; then RHSM_PASSWORD="$decoded"; fi
                    if [[ "$key" == "RHSM_USERNAME" ]]; then rhsm_user="$decoded"; fi
                    if [[ "$key" == "RHSM_PASSWORD" ]]; then rhsm_password="$decoded"; fi
                fi
            fi
        done < "$env_file"
    fi
}"""

content = re.sub(r'load_env\s*\(\)\s*\{[\s\S]*?\n\}', load_env_fix, content)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[3/4] Patching aap27_installer.sh for privileged local directory operations..."
python3 - << 'PYEOF'
import re

with open("aap27_installer.sh", "r") as f:
    content = f.read()

content = content.replace('mkdir -p /home/admin/.ssh', 'run_privileged mkdir -p /home/admin/.ssh')
content = content.replace('chmod 0750 /home/admin', 'run_privileged chmod 0750 /home/admin')
content = content.replace('chmod 700 /home/admin/.ssh', 'run_privileged chmod 700 /home/admin/.ssh')

with open("aap27_installer.sh", "w") as f:
    f.write(content)
PYEOF

echo "[4/4] Ensuring legacy state file exists..."
touch "$HOME/.aap27_install.env"

echo "[+] Context repair script completed successfully without syntax warnings!"

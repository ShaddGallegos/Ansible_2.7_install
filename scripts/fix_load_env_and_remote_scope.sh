#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"
TARGET_LIB="${SCRIPT_DIR}/lib/target.sh"
INSTALLER="${SCRIPT_DIR}/aap27_installer.sh"

echo "[1/3] Patching load_env in lib/state.sh for hybrid Vault + Base64 reading..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

robust_load_env = r"""load_env() {
    local key val line
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    if [[ -f "$env_file" ]]; then
        # 1. Read Base64/Plaintext lines directly from env.yml
        while IFS= read -r line; do
            if [[ "$line" =~ ^([A-Za-z0-9_]+)_B64=([A-Za-z0-9+/=]+)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="$(printf %s "${BASH_REMATCH[2]}" | base64 --decode 2>/dev/null || echo "")"
                if [[ -n "$val" ]]; then printf -v "$key" %s "$val"; fi
            elif [[ "$line" =~ ^([A-Za-z0-9_]+)='?(.*)'?$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                if [[ -n "$val" && "$key" != "\$ANSIBLE_VAULT" ]]; then printf -v "$key" %s "$val"; fi
            fi
        done < "$env_file"

        # 2. Query Vault for encrypted items if python helper is available
        if [[ -x "$py_bin" && -f "$helper" ]]; then
            for key in rhsm_user rhsm_password RHSM_USERNAME RHSM_PASSWORD root_password ROOT_PASSWORD INSTALL_SCOPE AAP_CONTROLLER_IP AAP_CONTROLLER_FQDN AAP_REMOTE_USER; do
                val="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "$key" 2>/dev/null || echo "")"
                if [[ -n "$val" ]]; then printf -v "$key" %s "$val"; fi
            done
        fi

        # 3. Alias variables
        if [[ -n "${rhsm_user:-}" ]]; then RHSM_USERNAME="$rhsm_user"; fi
        if [[ -n "${rhsm_password:-}" ]]; then RHSM_PASSWORD="$rhsm_password"; fi
        if [[ -n "${RHSM_USERNAME:-}" ]]; then rhsm_user="$RHSM_USERNAME"; fi
        if [[ -n "${RHSM_PASSWORD:-}" ]]; then rhsm_password="$RHSM_PASSWORD"; fi
        if [[ -n "${root_password:-}" ]]; then ROOT_PASSWORD="$root_password"; fi
        if [[ -n "${ROOT_PASSWORD:-}" ]]; then root_password="$ROOT_PASSWORD"; fi
    fi
}"""

content = re.sub(r'load_env\s*\(\)\s*\{[\s\S]*?\n\}', robust_load_env, content)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/3] Ensuring get_install_scope exists in lib/target.sh..."
python3 - << 'PYEOF'
with open("lib/target.sh", "r") as f:
    content = f.read()

get_scope_func = r"""
get_install_scope() {
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local scope=""
    if [[ -f "$env_file" ]]; then
        scope="$(grep -oP '^INSTALL_SCOPE_B64=\K.*' "$env_file" | base64 --decode 2>/dev/null || echo "")"
    fi
    echo "${scope:-${INSTALL_SCOPE:-local}}"
}
"""

if "get_install_scope()" not in content:
    content += get_scope_func

with open("lib/target.sh", "w") as f:
    f.write(content)
PYEOF

echo "[3/3] Patching aap27_installer.sh to enforce remote bypass on Step 2..."
python3 - << 'PYEOF'
import re

with open("aap27_installer.sh", "r") as f:
    content = f.read()

# Force load_env call at beginning of setup_admin_user and enforce get_install_scope check
setup_admin_patch = r"""setup_admin_user() {
    load_env
    INSTALL_SCOPE="$(get_install_scope)"
    if [[ "$INSTALL_SCOPE" == "remote" ]]; then
        log "Remote installation target detected ($INSTALL_SCOPE). Skipping local admin user setup."
        return 0
    fi"""

content = re.sub(r'setup_admin_user\s*\(\)\s*\{', setup_admin_patch, content)

# Wrap local admin directory modifications in run_privileged
content = content.replace('mkdir -p /home/admin/.ssh', 'run_privileged mkdir -p /home/admin/.ssh')
content = content.replace('chmod 0750 /home/admin', 'run_privileged chmod 0750 /home/admin')
content = content.replace('chmod 700 /home/admin/.ssh', 'run_privileged chmod 700 /home/admin/.ssh')

with open("aap27_installer.sh", "w") as f:
    f.write(content)
PYEOF

echo "[+] Master repair patch applied successfully!"

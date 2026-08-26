#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"
ENV_FILE="$HOME/.ansible/conf/env.yml"
VAULT_PASS="$HOME/.ansible/conf/.vaultpass.txt"
PY_BIN="${SCRIPT_DIR}/.venv-aap27/bin/python3"
HELPER="${SCRIPT_DIR}/lib/env_yaml.py"
PROJECT_KEY="Ansible_2.7_install"

echo "[1/4] Destroying corrupted env.yml file..."
rm -f "$ENV_FILE"
mkdir -p "$HOME/.ansible/conf"

echo "[2/4] Generating a fresh Vault structure..."
"$PY_BIN" "$HELPER" ensure-structure "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY"
chmod 600 "$ENV_FILE"

echo "[3/4] Prompting for credentials and saving to fresh Vault..."
read -r -p "Enter RHSM Username (email) [shadd@redhat.com]: " RHSM_U
RHSM_U="${RHSM_U:-shadd@redhat.com}"

read -r -s -p "Enter RHSM Password: " RHSM_P
echo ""

"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_user" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_USERNAME" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_password" "$RHSM_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_PASSWORD" "$RHSM_P"

echo "[4/4] Patching state.sh load_env to bypass legacy regex parsing..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

# Replace load_env with a vault-aware implementation that reads directly from python helper
load_env_fix = """load_env() {
    local key val
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    if [[ -f "$env_file" && -x "$py_bin" && -f "$helper" ]]; then
        for key in rhsm_user rhsm_password RHSM_USERNAME RHSM_PASSWORD INSTALL_SCOPE AAP_CONTROLLER_IP AAP_CONTROLLER_FQDN AAP_REMOTE_USER; do
            val="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "$key" 2>/dev/null || echo "")"
            if [[ -n "$val" ]]; then
                printf -v "$key" %s "$val"
            fi
        done
        if [[ -n "${rhsm_user:-}" ]]; then RHSM_USERNAME="$rhsm_user"; fi
        if [[ -n "${rhsm_password:-}" ]]; then RHSM_PASSWORD="$rhsm_password"; fi
        if [[ -n "${RHSM_USERNAME:-}" ]]; then rhsm_user="$RHSM_USERNAME"; fi
        if [[ -n "${RHSM_PASSWORD:-}" ]]; then rhsm_password="$RHSM_PASSWORD"; fi
    fi
}"""

content = re.sub(r'load_env\s*\(\)\s*\{[\s\S]*?\n\}', load_env_fix, content)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

touch "$HOME/.aap27_install.env"
echo "[+] Vault and load_env repaired successfully!"

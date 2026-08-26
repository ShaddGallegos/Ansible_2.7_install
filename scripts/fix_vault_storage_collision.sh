#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"
TARGET_LIB="${SCRIPT_DIR}/lib/target.sh"
ENV_FILE="$HOME/.ansible/conf/env.yml"
VAULT_PASS="$HOME/.ansible/conf/.vaultpass.txt"
PY_BIN="${SCRIPT_DIR}/.venv-aap27/bin/python3"
HELPER="${SCRIPT_DIR}/lib/env_yaml.py"
PROJECT_KEY="Ansible_2.7_install"

echo "[1/4] Destroying corrupted env.yml file and initializing Vault..."
rm -f "$ENV_FILE"
mkdir -p "$HOME/.ansible/conf"

if [[ ! -f "$VAULT_PASS" ]]; then
    echo "Ansible_2.7_install_vault_secret" > "$VAULT_PASS"
    chmod 600 "$VAULT_PASS"
fi

"$PY_BIN" "$HELPER" ensure-structure "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY"
chmod 600 "$ENV_FILE"

echo "[2/4] Prompting for credentials and saving directly into Vault..."
read -r -p "Enter RHSM Username (email) [shadd@redhat.com]: " RHSM_U
RHSM_U="${RHSM_U:-shadd@redhat.com}"

read -r -s -p "Enter RHSM Password: " RHSM_P
echo ""

read -r -s -p "Enter Target Host Root Password: " ROOT_P
echo ""

"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_user" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_USERNAME" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_password" "$RHSM_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_PASSWORD" "$RHSM_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "root_password" "$ROOT_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "ROOT_PASSWORD" "$ROOT_P"

echo "[3/4] Patching save_env_kv in lib/state.sh to use env_yaml.py instead of plaintext appending..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

# Replace save_env_kv to write state values using Python Vault helper
save_kv_fix = r"""save_env_kv() {
    local key="$1"
    local val="$2"
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    if [[ -f "$env_file" && -x "$py_bin" && -f "$helper" ]]; then
        "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "$key" "$val" 2>/dev/null || true
    fi
}"""

content = re.sub(r'save_env_kv\s*\(\)\s*\{[\s\S]*?\n\}', save_kv_fix, content)

# Replace load_env to query Vault keys via env_yaml.py
load_env_fix = r"""load_env() {
    local key val
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    if [[ -f "$env_file" && -x "$py_bin" && -f "$helper" ]]; then
        for key in rhsm_user rhsm_password RHSM_USERNAME RHSM_PASSWORD root_password ROOT_PASSWORD INSTALL_SCOPE AAP_CONTROLLER_IP AAP_CONTROLLER_FQDN AAP_REMOTE_USER; do
            val="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" "$key" 2>/dev/null || echo "")"
            if [[ -n "$val" ]]; then
                printf -v "$key" %s "$val"
            fi
        done
        if [[ -n "${rhsm_user:-}" ]]; then RHSM_USERNAME="$rhsm_user"; fi
        if [[ -n "${rhsm_password:-}" ]]; then RHSM_PASSWORD="$rhsm_password"; fi
        if [[ -n "${RHSM_USERNAME:-}" ]]; then rhsm_user="$RHSM_USERNAME"; fi
        if [[ -n "${RHSM_PASSWORD:-}" ]]; then rhsm_password="$RHSM_PASSWORD"; fi
        if [[ -n "${root_password:-}" ]]; then ROOT_PASSWORD="$root_password"; fi
        if [[ -n "${ROOT_PASSWORD:-}" ]]; then root_password="$ROOT_PASSWORD"; fi
    fi
}"""

content = re.sub(r'load_env\s*\(\)\s*\{[\s\S]*?\n\}', load_env_fix, content)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[4/4] Ensuring legacy state placeholder exists..."
touch "$HOME/.aap27_install.env"

echo "[+] Storage collision repair complete!"

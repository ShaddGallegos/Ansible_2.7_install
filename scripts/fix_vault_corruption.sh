#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HOME/.ansible/conf/env.yml"
VAULT_PASS="$HOME/.ansible/conf/.vaultpass.txt"
PY_BIN="${SCRIPT_DIR}/.venv-aap27/bin/python3"
HELPER="${SCRIPT_DIR}/lib/env_yaml.py"
PROJECT_KEY="Ansible_2.7_install"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"

echo "[1/4] Destroying corrupted env.yml file..."
rm -f "$ENV_FILE"
mkdir -p "$HOME/.ansible/conf"

# Ensure vaultpass file exists
if [[ ! -f "$VAULT_PASS" ]]; then
    echo "Ansible_2.7_install_vault_secret" > "$VAULT_PASS"
    chmod 600 "$VAULT_PASS"
fi

echo "[2/4] Generating a fresh Vault structure..."
"$PY_BIN" "$HELPER" ensure-structure "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY"
chmod 600 "$ENV_FILE"

echo "[3/4] Capturing credentials and populating Vault..."
read -r -p "Enter RHSM Username (email) [shadd@redhat.com]: " RHSM_U
RHSM_U="${RHSM_U:-shadd@redhat.com}"

read -r -s -p "Enter RHSM Password: " RHSM_P
echo ""

"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_user" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_USERNAME" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_password" "$RHSM_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_PASSWORD" "$RHSM_P"

echo "[4/4] Updating ensure_rhsm_credentials_exist in lib/state.sh to handle vault resets..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

robust_credentials_func = """ensure_rhsm_credentials_exist() {
    local env_file="$1"
    local vault_pass="$2"
    local proj_key="$3"
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"

    # Test if vault is readable; if corrupted, rebuild it
    if ! "$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user &>/dev/null; then
        echo -e "[!] Vault corruption detected in $env_file. Resetting vault structure..."
        rm -f "$env_file"
        "$py_bin" "$helper" ensure-structure "$env_file" "$vault_pass" "$proj_key"
        chmod 600 "$env_file"
    fi

    local u p t
    u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user 2>/dev/null || echo "")"
    [[ -z "$u" ]] && u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_USERNAME 2>/dev/null || echo "")"
    p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_password 2>/dev/null || echo "")"
    [[ -z "$p" ]] && p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_PASSWORD 2>/dev/null || echo "")"

    if [[ -z "$u" ]]; then
        echo -e "[!] RHSM_USERNAME is missing."
        read -r -p "Enter RHSM_USERNAME: " u
        if [[ -n "$u" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "rhsm_user" "$u"
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "RHSM_USERNAME" "$u"
        else
            echo "[ERR] Username required." >&2; exit 1
        fi
    fi

    if [[ -z "$p" ]]; then
        echo -e "[!] RHSM_PASSWORD is missing."
        read -r -s -p "Enter RHSM_PASSWORD: " p
        echo ""
        if [[ -n "$p" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "rhsm_password" "$p"
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "RHSM_PASSWORD" "$p"
        else
            echo "[ERR] Password required." >&2; exit 1
        fi
    fi
}"""

content = re.sub(r'ensure_rhsm_credentials_exist\s*\(\)\s*\{[\s\S]*?\n\}', robust_credentials_func, content)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

touch "$HOME/.aap27_install.env"
echo "[+] Vault repair complete!"

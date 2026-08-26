#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"
TARGET_LIB="${SCRIPT_DIR}/lib/target.sh"
INSTALLER="${SCRIPT_DIR}/aap27_installer.sh"
ENV_FILE="$HOME/.ansible/conf/env.yml"
VAULT_PASS="$HOME/.ansible/conf/.vaultpass.txt"
PY_BIN="${SCRIPT_DIR}/.venv-aap27/bin/python3"
HELPER="${SCRIPT_DIR}/lib/env_yaml.py"
PROJECT_KEY="Ansible_2.7_install"

echo "[1/4] Cleaning corrupted Vault file..."
rm -f "$ENV_FILE"
mkdir -p "$HOME/.ansible/conf"

if [[ ! -f "$VAULT_PASS" ]]; then
    echo "Ansible_2.7_install_vault_secret" > "$VAULT_PASS"
    chmod 600 "$VAULT_PASS"
fi

echo "[2/4] Initializing clean Vault structure..."
"$PY_BIN" "$HELPER" ensure-structure "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY"
chmod 600 "$ENV_FILE"

echo "[3/4] Prompting for missing credentials..."
read -r -p "Enter RHSM Username (email) [shadd@redhat.com]: " RHSM_U
RHSM_U="${RHSM_U:-shadd@redhat.com}"

read -r -s -p "Enter RHSM Password: " RHSM_P
echo ""

read -r -s -p "Enter Target Host Root Password (192.168.122.84): " ROOT_P
echo ""

echo "[+] Storing variables securely in Vault..."
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_user" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_USERNAME" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_password" "$RHSM_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_PASSWORD" "$RHSM_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "root_password" "$ROOT_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "ROOT_PASSWORD" "$ROOT_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "INSTALL_SCOPE" "remote"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "AAP_CONTROLLER_IP" "192.168.122.84"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "AAP_CONTROLLER_FQDN" "aap.prod.spg"

echo "[4/4] Updating helper functions in codebase..."
python3 - << 'PYEOF'
import re

# Update target.sh to ensure get_install_scope returns remote
with open("lib/target.sh", "r") as f:
    target_src = f.read()

get_scope_code = r"""
get_install_scope() {
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local scope=""

    if [[ -f "$env_file" && -x "$py_bin" && -f "$helper" ]]; then
        scope="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" Ansible_2.7_install INSTALL_SCOPE 2>/dev/null || echo "")"
    fi
    echo "${scope:-remote}"
}
"""

if "get_install_scope()" in target_src:
    target_src = re.sub(r'get_install_scope\s*\(\)\s*\{[\s\S]*?\n\}', get_scope_code.strip(), target_src)
else:
    target_src += "\n" + get_scope_code.strip() + "\n"

with open("lib/target.sh", "w") as f:
    f.write(target_src)

# Update aap27_installer.sh setup_admin_user to bypass local admin creation on remote install
with open("aap27_installer.sh", "r") as f:
    installer_src = f.read()

setup_admin_code = r"""setup_admin_user() {
    load_env
    local scope
    scope="$(get_install_scope)"
    if [[ "$scope" == "remote" ]]; then
        log "Remote installation target detected ($scope). Skipping local admin user setup."
        return 0
    fi"""

installer_src = re.sub(r'setup_admin_user\s*\(\)\s*\{', setup_admin_code, installer_src)

with open("aap27_installer.sh", "w") as f:
    f.write(installer_src)
PYEOF

touch "$HOME/.aap27_install.env"
echo "[+] Repair applied successfully!"

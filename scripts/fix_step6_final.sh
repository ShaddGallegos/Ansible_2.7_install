#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"
ENV_FILE="$HOME/.ansible/conf/env.yml"
VAULT_PASS="$HOME/.ansible/conf/.vaultpass.txt"
PY_BIN="${SCRIPT_DIR}/.venv-aap27/bin/python3"
HELPER="${SCRIPT_DIR}/lib/env_yaml.py"
PROJECT_KEY="Ansible_2.7_install"

echo "[1/4] Restoring lib/state.sh and fixing state_key_allowed syntax..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

# Fix nested duplicate 'case "$1" in' lines
content = re.sub(r'(\s*case\s+"\$(1|key)"\s+in\s*){2,}', r'\n    case "$1" in\n', content)

# Replace state_key_allowed with a clean implementation
clean_func = """state_key_allowed() {
    case "$1" in
        rhsm_user|rhsm_password|rh_offline_token|rh_ah_token|RHSM_USERNAME|RHSM_PASSWORD|INSTALL_SCOPE|AAP_CONTROLLER_IP|AAP_CONTROLLER_FQDN|AAP_CONTROLLER_SSH_KEY|AAP_REMOTE_USER|GLOBAL|AAP)
            return 0 ;;
        *)
            return 1 ;;
    esac
}"""

content = re.sub(r'state_key_allowed\s*\(\)\s*\{[\s\S]*?\}', clean_func, content)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/4] Ensuring clean Vault structure..."
mkdir -p "$HOME/.ansible/conf"
if [[ ! -f "$ENV_FILE" ]] || ! "$PY_BIN" "$HELPER" get-value "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" rhsm_user &>/dev/null; then
    echo "[!] Rebuilding Vault structure in $ENV_FILE..."
    [[ -f "$ENV_FILE" ]] && mv "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
    "$PY_BIN" "$HELPER" ensure-structure "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY"
    chmod 600 "$ENV_FILE"
fi

echo "[3/4] Capturing RHSM credentials..."
read -r -p "Enter RHSM Username (email) [shadd@redhat.com]: " RHSM_U
RHSM_U="${RHSM_U:-shadd@redhat.com}"

read -r -s -p "Enter RHSM Password: " RHSM_P
echo ""

echo "[4/4] Writing keys into encrypted env.yml..."
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_user" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_USERNAME" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_password" "$RHSM_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_PASSWORD" "$RHSM_P"

touch "$HOME/.aap27_install.env"
echo "[+] Repair script completed successfully!"

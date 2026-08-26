#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"
ENV_FILE="$HOME/.ansible/conf/env.yml"
VAULT_PASS="$HOME/.ansible/conf/.vaultpass.txt"
PY_BIN="${SCRIPT_DIR}/.venv-aap27/bin/python3"
HELPER="${SCRIPT_DIR}/lib/env_yaml.py"
PROJECT_KEY="Ansible_2.7_install"

echo "[1/4] Ensuring legacy state file exists..."
touch "$HOME/.aap27_install.env"

echo "[2/4] Patching state_key_allowed in lib/state.sh..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

# Allow both lowercase and uppercase RHSM keys in state_key_allowed
if "rhsm_user|rhsm_password" not in content:
    content = re.sub(
        r'(state_key_allowed\s*\(\)\s*\{[\s\S]*?case\s+"\$1"\s+in)',
        r'\1\n        rhsm_user|rhsm_password|rh_offline_token|rh_ah_token|RHSM_USERNAME|RHSM_PASSWORD)',
        content,
        count=1
    )

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[3/4] Validating and repairing env.yml Vault integrity..."
rebuild_vault=false

# Test if Vault is readable
if [[ -f "$ENV_FILE" ]]; then
    if ! "$PY_BIN" "$HELPER" get-value "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" rhsm_user &>/dev/null; then
        echo -e "[!] Vault format corruption or missing key detected in $ENV_FILE."
        rebuild_vault=true
    fi
else
    rebuild_vault=true
fi

if [[ "$rebuild_vault" == true ]]; then
    echo "[+] Rebuilding clean encrypted Vault structure..."
    mkdir -p "$HOME/.ansible/conf"
    [[ -f "$ENV_FILE" ]] && mv "$ENV_FILE" "${ENV_FILE}.corrupted.$(date +%s)"
    
    "$PY_BIN" "$HELPER" ensure-structure "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY"
    chmod 600 "$ENV_FILE"

    echo ""
    read -r -p "Enter RHSM Username (email) [shadd@redhat.com]: " RHSM_U
    RHSM_U="${RHSM_U:-shadd@redhat.com}"
    read -r -s -p "Enter RHSM Password: " RHSM_P
    echo ""

    echo "[+] Writing credentials to encrypted Vault..."
    "$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_user" "$RHSM_U"
    "$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_USERNAME" "$RHSM_U"
    "$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_password" "$RHSM_P"
    "$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_PASSWORD" "$RHSM_P"
fi

echo "[4/4] Patching aap27_installer.sh for safe set -e execution..."
python3 - << 'PYEOF'
import re

with open("aap27_installer.sh", "r") as f:
    content = f.read()

# Make missing .env file check safe under set -e
content = re.sub(
    r'\[\[ -f "\$HOME/\.aap27_install\.env" \]\]',
    'if [[ -f "$HOME/.aap27_install.env" ]]; then source "$HOME/.aap27_install.env" || true; fi',
    content
)

with open("aap27_installer.sh", "w") as f:
    f.write(content)
PYEOF

echo "[+] Auto-fix patch successfully applied!"

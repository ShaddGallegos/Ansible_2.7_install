#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"
ENV_FILE="$HOME/.ansible/conf/env.yml"
VAULT_PASS="$HOME/.ansible/conf/.vaultpass.txt"
PY_BIN="${SCRIPT_DIR}/.venv-aap27/bin/python3"
HELPER="${SCRIPT_DIR}/lib/env_yaml.py"

echo "[1/3] Patching lib/state.sh for RHSM variable mapping..."
python3 - << 'PYEOF'
with open("lib/state.sh", "r") as f:
    content = f.read()

# Map rhsm_user / rhsm_password to uppercase RHSM_USERNAME / RHSM_PASSWORD during load_env
old_assign = 'printf -v "$key" %s "$decoded"'
new_assign = '''if [[ "$key" == "rhsm_user" ]]; then
                rhsm_user="$decoded"
                RHSM_USERNAME="$decoded"
            elif [[ "$key" == "rhsm_password" ]]; then
                rhsm_password="$decoded"
                RHSM_PASSWORD="$decoded"
            else
                printf -v "$key" %s "$decoded"
            fi'''

if old_assign in content:
    content = content.replace(old_assign, new_assign)

# Ensure state_key_allowed permits both lowercase and uppercase variants
if "rhsm_user|rhsm_password|RHSM_USERNAME|RHSM_PASSWORD" not in content:
    content = content.replace(
        'state_key_allowed() {',
        'state_key_allowed() {\n    case "$1" in\n        rhsm_user|rhsm_password|rh_offline_token|rh_ah_token|RHSM_USERNAME|RHSM_PASSWORD)\n            return 0 ;;\n    esac'
    )

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/3] Checking credentials in env.yml..."
RHSM_U=$("$PY_BIN" "$HELPER" get-value "$ENV_FILE" "$VAULT_PASS" Ansible_2.7_install rhsm_user 2>/dev/null || echo "")
if [[ -z "$RHSM_U" ]]; then
    RHSM_U=$("$PY_BIN" "$HELPER" get-value "$ENV_FILE" "$VAULT_PASS" Ansible_2.7_install RHSM_USERNAME 2>/dev/null || echo "")
fi

if [[ -z "$RHSM_U" ]]; then
    read -r -p "Enter RHSM Username (email): " input_u
    RHSM_U="$input_u"
fi

RHSM_P=$("$PY_BIN" "$HELPER" get-value "$ENV_FILE" "$VAULT_PASS" Ansible_2.7_install rhsm_password 2>/dev/null || echo "")
if [[ -z "$RHSM_P" ]]; then
    RHSM_P=$("$PY_BIN" "$HELPER" get-value "$ENV_FILE" "$VAULT_PASS" Ansible_2.7_install RHSM_PASSWORD 2>/dev/null || echo "")
fi

if [[ -z "$RHSM_P" ]]; then
    read -r -s -p "Enter RHSM Password: " input_p
    echo ""
    RHSM_P="$input_p"
fi

echo "[3/3] Synchronizing RHSM keys in encrypted env.yml..."
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" Ansible_2.7_install "rhsm_user" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" Ansible_2.7_install "RHSM_USERNAME" "$RHSM_U"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" Ansible_2.7_install "rhsm_password" "$RHSM_P"
"$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" Ansible_2.7_install "RHSM_PASSWORD" "$RHSM_P"

touch "$HOME/.aap27_install.env"
echo "[+] Repair complete!"

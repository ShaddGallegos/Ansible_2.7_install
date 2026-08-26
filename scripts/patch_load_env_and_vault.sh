#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"
ENV_FILE="$HOME/.ansible/conf/env.yml"
VAULT_PASS="$HOME/.ansible/conf/.vaultpass.txt"
PY_BIN="${SCRIPT_DIR}/.venv-aap27/bin/python3"
HELPER="${SCRIPT_DIR}/lib/env_yaml.py"
PROJECT_KEY="Ansible_2.7_install"

echo "[1/4] Patching load_env and state key handler in lib/state.sh..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

# Replace load_env implementation to safely query env_yaml.py dump-b64 output
load_env_fix = """load_env() {
    local line key encoded decoded
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    if [[ -f "$env_file" && -x "$py_bin" && -f "$helper" ]]; then
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
        done < <("$py_bin" "$helper" dump-b64 "$env_file" "$vault_pass" "$proj_key" 2>/dev/null || true)
    fi
}"""

content = re.sub(r'load_env\s*\(\)\s*\{[\s\S]*?\n\}', load_env_fix, content)

# Update state_key_allowed to validate both case variations
allowed_fix = """state_key_allowed() {
    case "$1" in
        rhsm_user|rhsm_password|rh_offline_token|rh_ah_token|RHSM_USERNAME|RHSM_PASSWORD|INSTALL_SCOPE|AAP_CONTROLLER_IP|AAP_CONTROLLER_FQDN|AAP_CONTROLLER_SSH_KEY|AAP_REMOTE_USER|GLOBAL|AAP)
            return 0 ;;
        *)
            return 0 ;;
    esac
}"""

content = re.sub(r'state_key_allowed\s*\(\)\s*\{[\s\S]*?\n\}', allowed_fix, content)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/4] Ensuring encrypted Vault structure is populated..."
mkdir -p "$HOME/.ansible/conf"
if [[ ! -f "$ENV_FILE" ]]; then
    "$PY_BIN" "$HELPER" ensure-structure "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY"
    chmod 600 "$ENV_FILE"
fi

echo "[3/4] Verifying stored credentials..."
CURRENT_U=$("$PY_BIN" "$HELPER" get-value "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" rhsm_user 2>/dev/null || echo "")
if [[ -z "$CURRENT_U" ]]; then
    read -r -p "Enter RHSM Username (email) [shadd@redhat.com]: " INPUT_U
    CURRENT_U="${INPUT_U:-shadd@redhat.com}"
    read -r -s -p "Enter RHSM Password: " CURRENT_P
    echo ""

    "$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_user" "$CURRENT_U"
    "$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_USERNAME" "$CURRENT_U"
    "$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "rhsm_password" "$CURRENT_P"
    "$PY_BIN" "$HELPER" set "$ENV_FILE" "$VAULT_PASS" "$PROJECT_KEY" "RHSM_PASSWORD" "$CURRENT_P"
fi

echo "[4/4] Ensuring legacy state file exists..."
touch "$HOME/.aap27_install.env"

echo "[+] Patch successfully applied!"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/aap27_installer.sh"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"

echo "[1/4] Ensuring legacy state file exists..."
touch "$HOME/.aap27_install.env"

echo "[2/4] Patching aap27_installer.sh for safe set -e execution..."
python3 - << 'PYEOF'
import re, sys

installer_path = "aap27_installer.sh"
with open(installer_path, "r") as f:
    content = f.read()

# Fix unhandled non-zero exit on [[ -f .aap27_install.env ]]
content = re.sub(
    r'\[\[ -f "\$HOME/\.aap27_install\.env" \]\]',
    'if [[ -f "$HOME/.aap27_install.env" ]]; then source "$HOME/.aap27_install.env" || true; fi',
    content
)

# Ensure ensure_rhsm_credentials_exist is called right after initialize_env_file
if "ensure_rhsm_credentials_exist" not in content:
    content = re.sub(
        r'(initialize_env_file\b)',
        r'\1\n    ensure_rhsm_credentials_exist "$ENV_FILE" "$VAULT_PASS_FILE" "$PROJECT_KEY"',
        content,
        count=1
    )

with open(installer_path, "w") as f:
    f.write(content)
PYEOF

echo "[3/4] Updating credential handler in lib/state.sh..."
sed -i 's/\$helper" set-value/\$helper" set/g' "$STATE_LIB" 2>/dev/null || true

if ! grep -q "ensure_rhsm_credentials_exist()" "$STATE_LIB"; then
cat << 'ENDFUNC' >> "$STATE_LIB"

ensure_rhsm_credentials_exist() {
    local env_file="$1"
    local vault_pass="$2"
    local proj_key="$3"
    local py_bin="${SCRIPT_DIR}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR}/lib/env_yaml.py"

    echo -e "\n[INFO] Checking required RHSM configuration in $env_file..."

    local u p t
    u=$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user 2>/dev/null || echo "")
    p=$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_password 2>/dev/null || echo "")
    t=$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rh_offline_token 2>/dev/null || echo "")

    if [[ -z "$u" ]]; then
        echo -e "[!] RHSM_USERNAME (rhsm_user) is missing."
        read -r -p "Enter RHSM_USERNAME: " u
        if [[ -n "$u" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "rhsm_user" "$u"
            echo "[+] Saved rhsm_user."
        else
            echo "[ERR] Username is required to continue." >&2; exit 1
        fi
    fi

    if [[ -z "$p" && -z "$t" ]]; then
        echo -e "[!] Neither RHSM Password nor Offline Token found."
        read -r -s -p "Enter RHSM_PASSWORD (leave blank if using offline token): " p
        echo ""
        if [[ -n "$p" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "rhsm_password" "$p"
            echo "[+] Saved rhsm_password."
        else
            read -r -p "Enter RH_OFFLINE_TOKEN: " t
            if [[ -n "$t" ]]; then
                "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "rh_offline_token" "$t"
                echo "[+] Saved rh_offline_token."
            else
                echo "[ERR] RHSM Password or Offline Token is required." >&2; exit 1
            fi
        fi
    fi
}
ENDFUNC
fi

echo "[4/4] All fixes successfully applied!"

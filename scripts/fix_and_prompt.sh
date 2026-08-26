#!/usr/bin/env bash
set -euo pipefail

TARGET_SCRIPT="aap27_installer.sh"

# 1. Create target env file if missing to clear immediate set -e trap
touch "$HOME/.aap27_install.env"

# 2. Append credential verification helper to lib/state.sh
cat << 'ENDFUNC' >> lib/state.sh

# Verifies required variables exist in env.yml; prompts interactively if missing
ensure_rhsm_credentials_exist() {
    local env_file="$1"
    local vault_pass="$2"
    local proj_key="$3"
    local py_bin="/home/sgallego/GIT/Ansible_2.7_install/.venv-aap27/bin/python3"
    local helper="/home/sgallego/GIT/Ansible_2.7_install/lib/env_yaml.py"

    echo -e "\n[INFO] Checking required RHSM configuration in $env_file..."

    local u p t
    u=$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user 2>/dev/null || echo "")
    p=$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_password 2>/dev/null || echo "")
    t=$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rh_offline_token 2>/dev/null || echo "")

    if [[ -z "$u" ]]; then
        echo -e "[!] RHSM_USERNAME (rhsm_user) is missing from $env_file."
        read -r -p "Enter RHSM_USERNAME: " u
        if [[ -n "$u" ]]; then
            "$py_bin" "$helper" set-value "$env_file" "$vault_pass" "$proj_key" "rhsm_user" "$u"
            echo "[+] Saved rhsm_user."
        else
            echo "[ERR] Username is required to continue." >&2; exit 1
        fi
    fi

    if [[ -z "$p" && -z "$t" ]]; then
        echo -e "[!] Neither RHSM Password nor Offline Token found in $env_file."
        read -r -s -p "Enter RHSM_PASSWORD (leave blank if using offline token): " p
        echo ""
        if [[ -n "$p" ]]; then
            "$py_bin" "$helper" set-value "$env_file" "$vault_pass" "$proj_key" "rhsm_password" "$p"
            echo "[+] Saved rhsm_password."
        else
            read -r -p "Enter RH_OFFLINE_TOKEN: " t
            if [[ -n "$t" ]]; then
                "$py_bin" "$helper" set-value "$env_file" "$vault_pass" "$proj_key" "rh_offline_token" "$t"
                echo "[+] Saved rh_offline_token."
            else
                echo "[ERR] RHSM Password or Offline Token is required." >&2; exit 1
            fi
        fi
    fi
}
ENDFUNC

# 3. Patch aap27_installer.sh using Python to fix syntax & inject function execution
python3 - << 'PYEOF'
import re

with open("aap27_installer.sh", "r") as f:
    content = f.read()

# Make the .env check set -e safe
content = re.sub(
    r'\[\[ -f "\$HOME/\.aap27_install\.env" \]\]',
    'if [[ -f "$HOME/.aap27_install.env" ]]; then source "$HOME/.aap27_install.env" || true; fi',
    content
)

# Call ensure_rhsm_credentials_exist directly after initialize_env_file inside main()
if "ensure_rhsm_credentials_exist" not in content:
    content = re.sub(
        r'(initialize_env_file\b)',
        r'\1\n    ensure_rhsm_credentials_exist "$ENV_FILE" "$VAULT_PASS_FILE" "$PROJECT_KEY"',
        content,
        count=1
    )

with open("aap27_installer.sh", "w") as f:
    f.write(content)
PYEOF

echo "[+] Script successfully patched!"

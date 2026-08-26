#!/usr/bin/env bash
set -euo pipefail

# 1. Ensure the missing env file exists so [[ -f ]] checks never fail
touch "$HOME/.aap27_install.env"

# 2. Append the credential verification function directly to lib/state.sh
cat << 'ENDFUNC' >> lib/state.sh

# Verifies that required RHSM credentials exist in env.yml, prompting if missing
ensure_rhsm_credentials_exist() {
    local env_file="$1"
    local vault_pass="$2"
    local proj_key="$3"
    local py_bin="/home/sgallego/GIT/Ansible_2.7_install/.venv-aap27/bin/python3"
    local helper="/home/sgallego/GIT/Ansible_2.7_install/lib/env_yaml.py"

    echo "[INFO] Validating RHSM configuration in $env_file..."

    local u p t
    u=$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user 2>/dev/null || echo "")
    p=$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_password 2>/dev/null || echo "")
    t=$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rh_offline_token 2>/dev/null || echo "")

    if [[ -z "$u" ]]; then
        echo -e "\n[!] RHSM_USERNAME is missing from $env_file"
        read -r -p "Enter RHSM_USERNAME: " u
        if [[ -n "$u" ]]; then
            "$py_bin" "$helper" set-value "$env_file" "$vault_pass" "$proj_key" "rhsm_user" "$u"
        else
            echo "[ERR] Username required." >&2; exit 1
        fi
    fi

    if [[ -z "$p" && -z "$t" ]]; then
        echo -e "\n[!] Neither RHSM Password nor Offline Token found in $env_file"
        read -r -s -p "Enter RHSM_PASSWORD (leave blank for token): " p
        echo ""
        if [[ -n "$p" ]]; then
            "$py_bin" "$helper" set-value "$env_file" "$vault_pass" "$proj_key" "rhsm_password" "$p"
        else
            read -r -p "Enter RH_OFFLINE_TOKEN: " t
            if [[ -n "$t" ]]; then
                "$py_bin" "$helper" set-value "$env_file" "$vault_pass" "$proj_key" "rh_offline_token" "$t"
            else
                echo "[ERR] Password or Token required." >&2; exit 1
            fi
        fi
    fi
}
ENDFUNC

# 3. Safely update aap27_installer.sh to use if-statement and call check function
python3 - << 'PYEOF'
import re

with open("aap27_installer.sh", "r") as f:
    content = f.read()

# Make [[ -f ]] set -e safe
content = re.sub(
    r'\[\[ -f "\$HOME/\.aap27_install\.env" \]\]',
    'if [[ -f "$HOME/.aap27_install.env" ]]; then source "$HOME/.aap27_install.env" || true; fi',
    content
)

# Insert ensure_rhsm_credentials_exist after initialize_env_file
if "ensure_rhsm_credentials_exist" not in content:
    content = re.sub(
        r'(initialize_env_file)',
        r'\1\n    ensure_rhsm_credentials_exist "$ENV_FILE" "$VAULT_PASS_FILE" "$PROJECT_KEY"',
        content,
        count=1
    )

with open("aap27_installer.sh", "w") as f:
    f.write(content)
PYEOF

echo "[+] Repair applied successfully!"

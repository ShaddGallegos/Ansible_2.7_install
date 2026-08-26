#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="aap27_installer.sh"

if [[ ! -f "$TARGET_FILE" ]]; then
    echo "Error: $TARGET_FILE not found." >&2
    exit 1
fi

echo "[1/3] Creating backup ($TARGET_FILE.bak)..."
cp "$TARGET_FILE" "$TARGET_FILE.bak"

echo "[2/3] Patching silent set -e exit on missing .env file..."
sed -i 's/\[\[ -f "$HOME\/\.aap27_install\.env" \]\]/if \[\[ -f "$HOME\/\.aap27_install\.env" \]\]; then source "$HOME\/\.aap27_install\.env" || true; fi/' "$TARGET_FILE"

echo "[3/3] Injecting interactive prompt handler for missing credentials..."
cat << 'ENDFUNC' >> lib/state.sh

# Interactive credential check triggered prior to installer workflow steps
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
        echo -e "[!] RHSM_USERNAME is missing."
        read -r -p "Enter RHSM_USERNAME: " u
        if [[ -n "$u" ]]; then
            "$py_bin" "$helper" set-value "$env_file" "$vault_pass" "$proj_key" "rhsm_user" "$u"
        else
            echo "[ERR] Username required." >&2; exit 1
        fi
    fi

    if [[ -z "$p" && -z "$t" ]]; then
        echo -e "[!] Neither RHSM Password nor Offline Token found."
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

# Call the function right after initialize_env_file inside main()
sed -i '/initialize_env_file/a \    ensure_rhsm_credentials_exist "$ENV_FILE" "$VAULT_PASS_FILE" "$PROJECT_KEY"' "$TARGET_FILE"

echo "[+] Fix applied successfully!"

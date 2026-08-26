#!/usr/bin/env bash
set -euo pipefail

STATE_LIB="lib/state.sh"

if ! grep -q "ensure_rhsm_credentials_exist()" "$STATE_LIB"; then
    echo "[+] Appending ensure_rhsm_credentials_exist to $STATE_LIB..."
    cat << 'ENDFUNC' >> "$STATE_LIB"

ensure_rhsm_credentials_exist() {
    local env_file="$1"
    local vault_pass="$2"
    local proj_key="$3"
    local py_bin
    py_bin="$(env_yaml_python 2>/dev/null || echo "/home/sgallego/GIT/Ansible_2.7_install/.venv-aap27/bin/python3")"
    local helper="${SCRIPT_DIR:-/home/sgallego/GIT/Ansible_2.7_install}/lib/env_yaml.py"

    echo -e "\n[INFO] Validating RHSM configuration in $env_file..."

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
    echo "[+] Function successfully added!"
else
    echo "[=] Function already exists in $STATE_LIB."
fi

#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="aap27_installer.sh"

if [[ ! -f "$TARGET_FILE" ]]; then
    echo "Error: $TARGET_FILE not found." >&2
    exit 1
fi

echo "Creating backup of $TARGET_FILE..."
cp "$TARGET_FILE" "$TARGET_FILE.bak_step6"

# Python execution wrapper to safely query/write to encrypted env.yml
get_env_var() {
    local key="$1"
    /home/sgallego/GIT/Ansible_2.7_install/.venv-aap27/bin/python3 \
        /home/sgallego/GIT/Ansible_2.7_install/lib/env_yaml.py get-value \
        /home/sgallego/.ansible/conf/env.yml \
        /home/sgallego/.ansible/conf/.vaultpass.txt \
        Ansible_2.7_install "$key" 2>/dev/null || echo ""
}

set_env_var() {
    local key="$1"
    local val="$2"
    /home/sgallego/GIT/Ansible_2.7_install/.venv-aap27/bin/python3 \
        /home/sgallego/GIT/Ansible_2.7_install/lib/env_yaml.py set-value \
        /home/sgallego/.ansible/conf/env.yml \
        /home/sgallego/.ansible/conf/.vaultpass.txt \
        Ansible_2.7_install "$key" "$val"
}

# Function to check and prompt for missing credentials
check_and_prompt_credentials() {
    echo -e "\n[INFO] Validating required credentials in env.yml..."

    local current_user
    current_user=$(get_env_var "rhsm_user")

    if [[ -z "$current_user" ]]; then
        echo -e "\n[!] RHSM_USERNAME is missing from env.yml."
        read -r -p "Enter RHSM_USERNAME (Red Hat Login/CDN username): " input_user
        if [[ -n "$input_user" ]]; then
            set_env_var "rhsm_user" "$input_user"
            echo "[+] Saved rhsm_user to env.yml"
        else
            echo "[ERR] RHSM_USERNAME cannot be empty." >&2
            exit 1
        fi
    fi

    local current_pass current_token
    current_pass=$(get_env_var "rhsm_password")
    current_token=$(get_env_var "rh_offline_token")

    if [[ -z "$current_pass" && -z "$current_token" ]]; then
        echo -e "\n[!] Neither RHSM Password nor Offline Token found in env.yml."
        read -r -s -p "Enter RHSM_PASSWORD (leave blank if providing offline token): " input_pass
        echo ""
        if [[ -n "$input_pass" ]]; then
            set_env_var "rhsm_password" "$input_pass"
            echo "[+] Saved rhsm_password to env.yml"
        else
            read -r -p "Enter RH_OFFLINE_TOKEN: " input_token
            if [[ -n "$input_token" ]]; then
                set_env_var "rh_offline_token" "$input_token"
                echo "[+] Saved rh_offline_token to env.yml"
            else
                echo "[ERR] Either RHSM_PASSWORD or RH_OFFLINE_TOKEN must be provided." >&2
                exit 1
            fi
        fi
    fi
}

echo "[+] Executing credential check & prompt..."
check_and_prompt_credentials

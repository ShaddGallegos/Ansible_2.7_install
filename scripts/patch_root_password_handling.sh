#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_LIB="${SCRIPT_DIR}/lib/target.sh"
STATE_LIB="${SCRIPT_DIR}/lib/state.sh"

echo "[1/2] Updating lib/state.sh to validate root_password in ensure_rhsm_credentials_exist..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

# Extend ensure_rhsm_credentials_exist to also validate root_password / ROOT_PASSWORD
patch_func = r"""
    local rp
    rp="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" root_password 2>/dev/null || echo "")"
    [[ -z "$rp" ]] && rp="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" ROOT_PASSWORD 2>/dev/null || echo "")"

    if [[ -z "$rp" && "$(get_install_scope 2>/dev/null || echo "")" == "remote" ]]; then
        echo -e "[!] Target host root_password (ROOT_PASSWORD) is missing from Vault."
        read -r -s -p "Enter root password for remote target host: " rp
        echo ""
        if [[ -n "$rp" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "root_password" "$rp"
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "ROOT_PASSWORD" "$rp"
            echo "[+] Saved root_password to Vault."
        fi
    fi
}"""

# Inject before closing brace of ensure_rhsm_credentials_exist
if "root_password" not in content:
    content = re.sub(r'(\n\}\s*#?\s*end\s*ensure_rhsm|\n\})\s*$', r'\1', content)
    content = re.sub(r'(ensure_rhsm_credentials_exist\s*\(\)\s*\{[\s\S]*?)(\n\})', r'\1' + patch_func, content, count=1)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/2] Updating bootstrap_remote_admin in lib/target.sh to use sshpass with root_password..."
python3 - << 'PYEOF'
import re

with open("lib/target.sh", "r") as f:
    content = f.read()

new_bootstrap = r"""
bootstrap_remote_admin() {
    local target_host="$1"
    local local_pub_key="$HOME/.ssh/id_ed25519.pub"
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    # Fetch RHSM and Root credentials from Vault
    local rhsm_u rhsm_p rhsm_token root_p
    rhsm_u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user 2>/dev/null || echo "")"
    [[ -z "$rhsm_u" ]] && rhsm_u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_USERNAME 2>/dev/null || echo "")"
    rhsm_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_password 2>/dev/null || echo "")"
    [[ -z "$rhsm_p" ]] && rhsm_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_PASSWORD 2>/dev/null || echo "")"
    rhsm_token="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rh_offline_token 2>/dev/null || echo "")"
    
    root_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" root_password 2>/dev/null || echo "")"
    [[ -z "$root_p" ]] && root_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" ROOT_PASSWORD 2>/dev/null || echo "")"

    # Prompt if root password is still missing
    if [[ -z "$root_p" ]]; then
        read -r -s -p "Enter root password for remote target host ($target_host): " root_p
        echo ""
        if [[ -n "$root_p" ]]; then
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "root_password" "$root_p"
            "$py_bin" "$helper" set "$env_file" "$vault_pass" "$proj_key" "ROOT_PASSWORD" "$root_p"
        fi
    fi

    # Ensure local SSH key exists on installer host
    if [[ ! -f "$local_pub_key" ]]; then
        echo "[INFO] Generating local SSH key pair on installer host..."
        ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" <<< y >/dev/null 2>&1 || true
    fi

    local pub_key_str
    pub_key_str="$(cat "$local_pub_key")"

    echo "[INFO] Bootstrapping target host $target_host via root@${target_host}..."

    # Build SSH command with sshpass if root_password is available
    local ssh_cmd=(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10)
    if [[ -n "$root_p" ]] && command -v sshpass &>/dev/null; then
        ssh_cmd=(sshpass -p "$root_p" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10)
    fi

    "${ssh_cmd[@]}" "root@${target_host}" bash -s <<REMOTE_BOOTSTRAP
set -euo pipefail

# 1. RHSM Registration check
if command -v subscription-manager &>/dev/null; then
    if ! subscription-manager status &>/dev/null; then
        echo "[INFO] Target host is not registered with RHSM. Registering..."
        if [[ -n "$rhsm_token" ]]; then
            subscription-manager register --offline_token="$rhsm_token" --auto-attach || true
        elif [[ -n "$rhsm_u" && -n "$rhsm_p" ]]; then
            subscription-manager register --username="$rhsm_u" --password="$rhsm_p" --auto-attach || true
        else
            echo "[WARN] No RHSM credentials provided; skipping subscription-manager registration."
        fi
    else
        echo "[OK] Target host is already registered with RHSM."
    fi
fi

# 2. System update
echo "[INFO] Updating system packages via dnf -y upgrade..."
dnf -y upgrade || yum -y upgrade

# 3. Create admin user and assign administrative/service groups
if ! id "admin" &>/dev/null; then
    useradd -m -s /bin/bash admin
    echo "[+] Created 'admin' user on target."
fi

for grp in wheel sudo podman docker systemd-journal input video; do
    getent group "\$grp" &>/dev/null || groupadd -r "\$grp" 2>/dev/null || true
    usermod -aG "\$grp" admin 2>/dev/null || true
done

# 4. Configure passwordless sudo for admin
echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin
chmod 0440 /etc/sudoers.d/admin

# 5. Inject local user's public SSH key into admin's authorized_keys
mkdir -p /home/admin/.ssh
chmod 700 /home/admin/.ssh
if ! grep -qF "$pub_key_str" /home/admin/.ssh/authorized_keys 2>/dev/null; then
    echo "$pub_key_str" >> /home/admin/.ssh/authorized_keys
fi
chown -R admin:admin /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys

# 6. Enable lingering for rootless Podman
loginctl enable-linger admin 2>/dev/null || true
REMOTE_BOOTSTRAP

    echo "[OK] Root bootstrap, RHSM registration, DNF upgrade, and admin user provisioning complete!"
}
"""

content = re.sub(r'bootstrap_remote_admin\s*\(\)\s*\{[\s\S]*?\n\}', new_bootstrap.strip(), content)

with open("lib/target.sh", "w") as f:
    f.write(content)
PYEOF

echo "[+] Root password handling and sshpass integration successfully applied!"

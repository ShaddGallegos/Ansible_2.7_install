#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_LIB="${SCRIPT_DIR}/lib/target.sh"
INSTALLER="${SCRIPT_DIR}/aap27_installer.sh"

echo "[1/2] Updating bootstrap_remote_admin in lib/target.sh..."
python3 - << 'PYEOF'
import re

with open("lib/target.sh", "r") as f:
    content = f.read()

new_bootstrap = """
bootstrap_remote_admin() {
    local target_host="$1"
    local local_pub_key="$HOME/.ssh/id_ed25519.pub"
    local py_bin="${SCRIPT_DIR:-.}/.venv-aap27/bin/python3"
    local helper="${SCRIPT_DIR:-.}/lib/env_yaml.py"
    local env_file="${ENV_FILE:-$HOME/.ansible/conf/env.yml}"
    local vault_pass="${VAULT_PASS_FILE:-$HOME/.ansible/conf/.vaultpass.txt}"
    local proj_key="${PROJECT_KEY:-Ansible_2.7_install}"

    # Fetch RHSM credentials from Vault
    local rhsm_u rhsm_p rhsm_token
    rhsm_u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_user 2>/dev/null || echo "")"
    [[ -z "$rhsm_u" ]] && rhsm_u="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_USERNAME 2>/dev/null || echo "")"
    rhsm_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rhsm_password 2>/dev/null || echo "")"
    [[ -z "$rhsm_p" ]] && rhsm_p="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" RHSM_PASSWORD 2>/dev/null || echo "")"
    rhsm_token="$("$py_bin" "$helper" get-value "$env_file" "$vault_pass" "$proj_key" rh_offline_token 2>/dev/null || echo "")"

    # Ensure local SSH key exists on installer host
    if [[ ! -f "$local_pub_key" ]]; then
        echo "[INFO] Generating local SSH key pair on installer host..."
        ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" <<< y >/dev/null 2>&1 || true
    fi

    local pub_key_str
    pub_key_str="$(cat "$local_pub_key")"

    echo "[INFO] Bootstrapping target host $target_host via root@${target_host}..."

    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${target_host}" bash -s <<REMOTE_BOOTSTRAP
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

# Create secondary groups if missing and append admin to all of them
for grp in wheel sudo podman docker systemd-journal input video; do
    getent group "\$grp" &>/dev/null || groupadd -r "\$grp" 2>/dev/null || true
    usermod -aG "\$grp" admin 2>/dev/null || true
done
echo "[+] Added 'admin' to administrative groups (wheel, sudo, podman, docker, systemd-journal, input, video)."

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

# Replace existing bootstrap_remote_admin function or append if missing
if "bootstrap_remote_admin()" in content:
    content = re.sub(r'bootstrap_remote_admin\s*\(\)\s*\{[\s\S]*?\n\}', new_bootstrap.strip(), content)
else:
    content += "\n" + new_bootstrap.strip() + "\n"

with open("lib/target.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/2] Verifying aap27_installer.sh contains bootstrap trigger..."
python3 - << 'PYEOF'
import re

with open("aap27_installer.sh", "r") as f:
    content = f.read()

if "bootstrap_remote_admin" not in content:
    content = re.sub(
        r'(run_full_install_step 2\b.*)',
        r'if [[ "$(get_install_scope)" == "remote" ]]; then bootstrap_remote_admin "$(get_install_target_host)"; fi\n    \1',
        content,
        count=1
    )
    with open("aap27_installer.sh", "w") as f:
        f.write(content)
PYEOF

echo "[+] Remote registration, DNF upgrade, and admin group patch applied successfully!"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_LIB="${SCRIPT_DIR}/lib/target.sh"
INSTALLER="${SCRIPT_DIR}/aap27_installer.sh"

echo "[1/3] Adding root-to-root bootstrap handler in lib/target.sh..."
python3 - << 'PYEOF'
import re

with open("lib/target.sh", "r") as f:
    content = f.read()

bootstrap_func = """
# Step 1: Root-level initial connection to bootstrap the admin user, SSH key, sudo, and Podman
bootstrap_remote_admin() {
    local target_host="$1"
    local local_pub_key="$HOME/.ssh/id_ed25519.pub"

    # Ensure local SSH key exists
    if [[ ! -f "$local_pub_key" ]]; then
        echo "[INFO] Generating local SSH key pair..."
        ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" <<< y >/dev/null 2>&1 || true
    fi

    local pub_key_str
    pub_key_str="$(cat "$local_pub_key")"

    echo "[INFO] Bootstrapping 'admin' user on $target_host using root credentials..."

    # SSH as root to target host to set up admin user, passwordless sudo, and SSH key
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${target_host}" bash -s <<REMOTE_BOOTSTRAP
set -euo pipefail

# 1. Create admin user if missing
if ! id "admin" &>/dev/null; then
    useradd -m -s /bin/bash admin
    echo "[+] Created 'admin' user on target system."
fi

# 2. Configure passwordless sudo for admin
echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin
chmod 0440 /etc/sudoers.d/admin
echo "[+] Configured passwordless sudo for admin."

# 3. Inject local user's public SSH key into admin's authorized_keys
mkdir -p /home/admin/.ssh
chmod 700 /home/admin/.ssh
if ! grep -qF "$pub_key_str" /home/admin/.ssh/authorized_keys 2>/dev/null; then
    echo "$pub_key_str" >> /home/admin/.ssh/authorized_keys
    echo "[+] Added installer SSH public key to admin@${target_host}."
fi
chown -R admin:admin /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys

# 4. Enable lingering for rootless Podman
loginctl enable-linger admin 2>/dev/null || true
REMOTE_BOOTSTRAP

    echo "[OK] Root bootstrap complete. Test connection as admin@${target_host}..."
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "admin@${target_host}" "id"
}
"""

if "bootstrap_remote_admin()" not in content:
    content += bootstrap_func

with open("lib/target.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/3] Injecting bootstrap call into aap27_installer.sh before target execution..."
python3 - << 'PYEOF'
import re

with open("aap27_installer.sh", "r") as f:
    content = f.read()

# Call bootstrap_remote_admin before running step 2 / remote target execution
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

echo "[3/3] Ensuring legacy state file exists..."
touch "$HOME/.aap27_install.env"

echo "[+] Root bootstrap patch successfully applied!"

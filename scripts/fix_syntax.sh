#!/usr/bin/env bash
set -euo pipefail

STATE_LIB="lib/state.sh"

echo "[1/2] Repairing syntax in $STATE_LIB..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

# Clean up any malformed case additions from previous sed attempts
content = re.sub(r'rhsm_user\|rhsm_password\|rh_offline_token\|rh_ah_token\)+', '', content)

# Correctly insert the missing keys into state_key_allowed
old_pattern = r'(state_key_allowed\s*\(\)\s*\{[\s\S]*?case\s+"\$1"\s+in)'
new_case = r'\1\n        rhsm_user|rhsm_password|rh_offline_token|rh_ah_token|RHSM_USERNAME|RHSM_PASSWORD)'

content = re.sub(old_pattern, new_case, content, count=1)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/2] Ensuring state file exists..."
touch "$HOME/.aap27_install.env"

echo "[+] Syntax repaired successfully!"

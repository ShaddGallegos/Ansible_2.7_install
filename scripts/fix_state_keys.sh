#!/usr/bin/env bash
set -euo pipefail

STATE_LIB="lib/state.sh"

echo "[1/2] Updating state_key_allowed in $STATE_LIB..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    content = f.read()

# Update state_key_allowed case block to explicitly accept rhsm_user and rhsm_password
case_pattern = r'(state_key_allowed\s*\(\)\s*\{[\s\S]*?case\s+"\$1"\s+in)'
replacement = r'\1\n        rhsm_user|rhsm_password|rh_offline_token|rh_ah_token)'

content = re.sub(case_pattern, replacement, content, count=1)

# Ensure variable assignment maps rhsm_user to RHSM_USERNAME if needed
content = content.replace(
    'printf -v "$key" %s "$decoded"',
    'if [[ "$key" == "rhsm_user" ]]; then rhsm_user="$decoded"; RHSM_USERNAME="$decoded"; else printf -v "$key" %s "$decoded"; fi'
)

with open("lib/state.sh", "w") as f:
    f.write(content)
PYEOF

echo "[2/2] Touch environment file..."
touch "$HOME/.aap27_install.env"

echo "[+] state.sh updated successfully!"

#!/usr/bin/env bash
set -euo pipefail

STATE_LIB="lib/state.sh"

echo "[1/3] Restoring lib/state.sh to git HEAD..."
git checkout HEAD -- "$STATE_LIB" 2>/dev/null || cp "${STATE_LIB}.bak" "$STATE_LIB" 2>/dev/null || true

echo "[2/3] Safely injecting allowed state keys..."
python3 - << 'PYEOF'
import re

with open("lib/state.sh", "r") as f:
    lines = f.readlines()

new_lines = []
inside_allowed_func = False

for line in lines:
    if "state_key_allowed()" in line:
        inside_allowed_func = True
    
    # Inject our keys right under the 'case "$1" in' line inside state_key_allowed()
    if inside_allowed_func and re.search(r'case\s+"\$(1|key)"\s+in', line):
        new_lines.append(line)
        new_lines.append("        rhsm_user|rhsm_password|rh_offline_token|rh_ah_token|RHSM_USERNAME|RHSM_PASSWORD)\n")
        new_lines.append("            return 0 ;;\n")
        inside_allowed_func = False
        continue

    new_lines.append(line)

with open("lib/state.sh", "w") as f:
    f.writelines(new_lines)
PYEOF

echo "[3/3] Ensuring state file exists..."
touch "$HOME/.aap27_install.env"

echo "[+] lib/state.sh successfully restored and patched!"

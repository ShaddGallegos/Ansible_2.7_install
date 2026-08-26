#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="aap27_installer.sh"

if [[ ! -f "$TARGET_FILE" ]]; then
    echo "Error: $TARGET_FILE not found in the current directory." >&2
    exit 1
fi

echo "Creating backup ($TARGET_FILE.bak)..."
cp "$TARGET_FILE" "$TARGET_FILE.bak"

# 1. Safely handle missing ~/.aap27_install.env without triggering set -e
sed -i 's/\[\[ -f.*\.aap27_install\.env.*\]\]/\[\[ -f "$HOME\/\.aap27_install\.env" \]\] \&\& source "$HOME\/\.aap27_install\.env" || true/' "$TARGET_FILE"

# 2. Fix potential unhandled non-zero return in require_root check
if grep -q "require_root" "$TARGET_FILE"; then
    sed -i '/require_root()/!b;n;c\    if [[ $EUID -ne 0 ]]; then echo "[-] Script must be run with root privileges (e.g. sudo bash aap27_installer.sh)"; exit 1; fi' "$TARGET_FILE"
fi

# 3. Ensure target env file exists and ends with a newline if present
TOUCH_ENV="$HOME/.aap27_install.env"
if [[ -f "$TOUCH_ENV" ]]; then
    echo "" >> "$TOUCH_ENV"
else
    touch "$TOUCH_ENV"
fi

echo "[+] Fixes successfully applied to $TARGET_FILE!"

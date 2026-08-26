#!/usr/bin/env bash
set -euo pipefail

TARGET="lib/state.sh"

if [[ -f "$TARGET" ]]; then
    echo "[+] Updating set-value calls to set in $TARGET..."
    sed -i 's/\$helper" set-value/\$helper" set/g' "$TARGET"
    echo "[+] Fixed $TARGET successfully!"
else
    echo "[-] Error: $TARGET not found." >&2
    exit 1
fi

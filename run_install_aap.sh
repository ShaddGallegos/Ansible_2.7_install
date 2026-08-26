#!/usr/bin/env bash
# Lightweight CLI wrapper to prompt for postgresql_admin_password
# and invoke the outer playbook with the provided secret as extra-vars.

set -euo pipefail

PLAYBOOK="aap_workflow_project/playbooks/install_aap.yml"

usage() {
  cat <<EOF
Usage: $0 [ansible-playbook options]

This script prompts (hidden) for the PostgreSQL admin password and
invokes the install playbook forwarding the secret as an extra-var.

Any positional/flag arguments are appended to the underlying
ansible-playbook invocation.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

read -r -s -p "PostgreSQL admin password for managed DB (press Enter to use default 'redhat'): " PG_PASS
echo
PG_PASS="${PG_PASS:-redhat}"

echo "Running playbook ${PLAYBOOK} (password will be forwarded securely)..."

# Forward the password via an extra var. Other extra-vars passed on CLI
# will override this if the caller explicitly provides them.
ansible-playbook "$PLAYBOOK" -e "postgresql_admin_password=${PG_PASS}" "$@"

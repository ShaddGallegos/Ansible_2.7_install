# Ansible_2.7_install local defaults/env.yml variable guide

This file documents variables in defaults/env.yml for standalone project use.

- Keep defaults/env.yml encrypted with ansible-vault.
- Vault password file is expected at ~/.ansible/conf/.defaults_env.vaultpass.txt by default.

## Variables

| Variable | Synopsis | More info |
|---|---|---|

## Sources

- Checklist: /home/sgallego/GIT/Ansible_2.7_install/CHECKLIST.md

## Current Implementation Status

Recent runtime fixes were implemented in collection patch overlays rather than in defaults values:

- Automation gateway readiness and TLS bootstrap behavior updates.
- Automation gateway service registration and routes loop correction.
- Receptor signing key transfer update from fetch to slurp/content copy to avoid temporary file permission failures.

This defaults area remains the variable reference layer; operational troubleshooting changes are tracked in repository and workflow README/CHECKLIST files.

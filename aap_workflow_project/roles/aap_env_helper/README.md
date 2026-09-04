# aap_env_helper

Remote prompt helper for AAP installer.

This helper is uploaded to the installer node and run as the installer user to prompt for missing secrets and persist them to `~/.ansible/conf/env.yml`. It expects keys as arguments and will prompt for each key if not present in the file.

## Usage (on installer node)

/home/admin/.ansible/bin/remote_prompt_and_write_env.sh controller_admin_password hub_admin_password

Note: the outer playbook uploads and runs the script when needed.

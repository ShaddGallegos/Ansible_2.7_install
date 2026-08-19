# Ansible_2.7_install local defaults/env.yml variable guide

This file documents variables in vars/env.yml for standalone project use.

- Keep vars/env.yml encrypted with ansible-vault.
- Vault password file is expected at ~/.ansible/conf/.defaults_env.vaultpass.txt by default.
- Set `aap27_defaults_use_local_env: true` when invoking this
	role to load the vaulted variables. Loading is opt-in so playbooks without
	the vault password continue to work.

```yaml
roles:
	- role: aap27_defaults
		vars:
			aap27_defaults_use_local_env: true
	- role: aap27_menu_installer
```

## Variables

| Variable | Synopsis | More info |
|---|---|---|

## Sources

- Checklist: `CHECKLIST.md` at the repository root

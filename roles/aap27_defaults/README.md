# AAP 2.7 local defaults

The optional `aap27_defaults` role loads installer variables from the vaulted
`~/.ansible/conf/env.yml` file, which is the single shared source of truth for
all local Ansible projects. Loading is opt-in so playbooks that do not have
the vault password continue to work.

- Keep `~/.ansible/conf/env.yml` encrypted with Ansible Vault and mode `0600`.
- The file has a `common:` section (values shared by any project) and one
  section per project (keyed by `aap27_defaults_project_key`, default
  `Ansible_2.7_install`); project keys override `common` on collision.
- The complete non-secret variable schema is in `templates/env.yml.example` at
	the repository root.
- The vault password file is expected at `~/.ansible/conf/.vaultpass.txt` and
  is created once and reused across all projects (never recreated).
- Set `aap27_defaults_use_local_env: true` when invoking this
  role to load the vaulted variables.

```yaml
roles:
	- role: aap27_defaults
		vars:
			aap27_defaults_use_local_env: true
	- role: aap27_menu_installer
```

Run the playbook with the vault password file:

```bash
ansible-playbook \
	--vault-password-file ~/.ansible/conf/.vaultpass.txt \
	playbook.yml
```

Override `aap27_defaults_env_file` when a different vaulted variable file is
required.

## Variable groups

The schema defines shell installer settings, target identity, bundle options,
resource thresholds, Red Hat credentials and tokens, AAP Controller resources,
workflow survey inputs, rootless Podman settings, and nested containerized
installer database credentials.

## Sources

- Checklist: `CHECKLIST.md` at the repository root

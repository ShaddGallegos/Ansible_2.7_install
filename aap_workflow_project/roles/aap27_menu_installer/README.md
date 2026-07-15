# aap27_menu_installer role

This role converts the shell-driven AAP 2.7 menu installer workflow into an Ansible role with step-based execution.

## Steps

- prework
- host_identity
- download_bundle
- install

Control steps with `aap27_menu_installer_selected_steps`.

## Example

```yaml
- hosts: all
  become: true
  roles:
    - role: aap27_menu_installer
      vars:
        aap27_menu_installer_selected_steps:
          - prework
          - host_identity
          - download_bundle
          - install
        aap27_menu_installer_execution_playbook: install
        aap27_menu_installer_remote_user: admin
        aap27_menu_installer_admin_password: "{{ admin_password }}"
        aap27_menu_installer_registry_username: "{{ rhsm_username }}"
        aap27_menu_installer_registry_password: "{{ rhsm_password }}"
```

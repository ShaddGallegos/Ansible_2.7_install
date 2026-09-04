# aap27_menu_installer role

This role converts the shell-driven AAP 2.7 menu installer workflow into an Ansible role with step-based execution.

## Steps

## Contents

- Steps
- Collection patches
- Example


- preflight
- prework
- host_identity
- download_bundle
- install

Control steps with `aap27_menu_installer_selected_steps`.

Admin identity and home are configurable with
`aap27_menu_installer_admin_user` and `aap27_menu_installer_admin_home`.

## Collection patches

`files/collection_patches/ansible/containerized_installer/` holds patch task
files applied over the vendored `ansible.containerized_installer` collection
(see `tasks/step_install.yml`). The manifest gates this active overlay to the
validated 2.7-2 bundle. Active patched roles are `automationgateway`, `common`,
and `postgresql`.

`files/collection_patch_candidates/2.7-4/` contains imported
`automationcontroller`, `preflight`, and `receptor` candidates. They are not
applied automatically until a complete 2.7-4 patch set is validated and added
to the active manifest.

## Example

```yaml
- hosts: all
  become: true
  roles:
    - role: aap27_menu_installer
      vars:
        aap27_menu_installer_selected_steps:
          - preflight
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

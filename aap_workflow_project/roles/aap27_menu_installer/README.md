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

      ## Recent Notes

      During current AAP 2.7 installer validation, runtime issues were addressed through collection patch overlays that this role relies on at execution time:

      - Automation gateway readiness/TLS behavior adjustments for loopback and startup sequencing.
      - Automation gateway service-node gather workaround to avoid restricted helper container execution.
      - Automation gateway route task loop restoration.
      - Receptor signing key transfer moved from fetch to slurp plus content-copy to avoid temporary file permission failures.

      Keep the repository `collection_patches` content in sync with extracted bundle overlays before running the install step.

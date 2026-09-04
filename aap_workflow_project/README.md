# AAP 2.7 Install Workflow Project

Lightweight Ansible project that generates controller resources (inventories, credentials, job and workflow templates) so the installer can be launched from the AAP UI using surveys.

## Contents

- What It Creates
- Files
- Prerequisites
- Run
- Design Notes

## What It Creates

- Organization
- Inventory
- Credentials
- Project (SCM-based)
- Job Templates with surveys
- Workflow Job Template with linked nodes

## SCM Project URL

- https://github.com/shaddgallegos/Ansible_2.7_install.git

## Files

- `playbooks/create_controller_resources.yml`
  - Creates controller objects (inventory, credentials, project, templates, workflow)
- `playbooks/prework.yml`
- `playbooks/host_identity.yml`
- `playbooks/download_bundle.yml`
- `playbooks/install_aap.yml`
- `group_vars/all.yml`
- `inventory/controller.ini.example`
- `CHECKLIST.md`

## Prerequisites

1. Install collection dependencies:

```bash
ansible-galaxy collection install -r requirements.yml
```

2. Copy `inventory/controller.ini.example` to `inventory/controller.ini`, or
  run the menu install-scope prompt to generate it. The operational inventory
  is intentionally ignored by Git.
3. Update `group_vars/all.yml` with controller URL and auth.
4. Set `machine_credential_username` to a non-root SSH user (for example `admin`).
5. Ensure controller token/user can manage resources.

## Run

```bash
ansible-playbook -i inventory/controller.ini playbooks/create_controller_resources.yml
```

## Design Notes

- Surveys are enabled on templates to collect runtime values.
- Install survey includes `remote_user`; it must be non-root to satisfy containerized installer preflight.
- Prework configures rootless podman for runtime `remote_user`, enables linger/user manager, and attempts `registry.redhat.io` login using RHSM credentials.
- Install playbook validates `remote_user` and `machine_credential_username` alignment before running `ansible.containerized_installer`.
- Workflow links templates in this sequence:
  - Prework -> Host Identity -> Download Bundle -> Install AAP

# AAP 2.7 Install Workflow Project

This project creates AAP controller resources so installation can be launched as workflow templates with surveys (instead of an interactive shell menu).

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
- `inventory/controller.ini`
- `CHECKLIST.md`

## Prerequisites

1. Install collection dependencies:

```bash
ansible-galaxy collection install -r requirements.yml
```

2. Update `group_vars/all.yml` with controller URL and auth.
3. Ensure controller token/user can manage resources.

## Run

```bash
ansible-playbook -i inventory/controller.ini playbooks/create_controller_resources.yml
```

## Design Notes

- Surveys are enabled on templates to collect runtime values.
- Workflow links templates in this sequence:
  - Prework -> Host Identity -> Download Bundle -> Install AAP

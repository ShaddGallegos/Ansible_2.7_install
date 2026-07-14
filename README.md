# AAP 2.7-2 Menu Installer Helper

This folder contains a menu-driven bash helper for preparing and installing Red Hat Ansible Automation Platform (AAP) 2.7-2 containerized setup bundle on a single node.

## Files

- `aap27_menu_installer.sh`: Interactive dynamic menu script.
- `CHECKLIST.md`: Linked installation checklist and prerequisites.

## What This Tool Does

- Shows a checklist and readiness status with links.
- Provides contextual guidance per step (for example: `6?`).
- Runs Step 1 preflight checks and auto-installs `podman` when missing.
- Performs common prework for AAP installs.
- Configures host identity requirements (FQDN, domain, `/etc/hosts`).
- Optionally disables firewall and sets SELinux to permissive for install workflows.
- Creates and configures an `admin` user with passwordless sudo and SSH keys.
- Captures required credentials/tokens and stores them in a local env file with restricted permissions.
- Logs runtime installer user into `registry.redhat.io` using RHSM credentials.
- Configures rootless podman for runtime installer user (`/etc/subuid`, `/etc/subgid`, linger, user bus, `podman.socket`, migrate).
- Downloads the AAP 2.7-2 containerized bundle to `/home/admin/Downloads/`.
- Extracts the bundle and updates `inventory-growth` with requested values.
- Runs selected execution playbooks from `ansible.containerized_installer`:
  - `install`
  - `backup`
  - `bundle`
  - `install_standalone_mcp`
  - `log_gathering`
  - `restore`
  - `uninstall`

## Ansible Workflow (Controller-Driven)

In addition to the local shell menu, this repo includes a controller-driven workflow project in `aap_workflow_project`.

This path is intended for running installation as AAP Job Templates and Workflow Templates with surveys.

### Workflow Directory

- `aap_workflow_project/playbooks/create_controller_resources.yml`
- `aap_workflow_project/playbooks/prework.yml`
- `aap_workflow_project/playbooks/host_identity.yml`
- `aap_workflow_project/playbooks/download_bundle.yml`
- `aap_workflow_project/playbooks/install_aap.yml`

### Workflow Setup

1. Install required collection(s):

```bash
cd /home/sgallego/GIT/Ansible_2.7_install/aap_workflow_project
ansible-galaxy collection install -r requirements.yml
```

2. Configure controller and credential values:

- Edit `aap_workflow_project/group_vars/all.yml`
- Set controller URL and auth (`aap_controller_host`, token or username/password)
- Set credential values (`machine_credential_*`, `registry_*`)

3. Confirm controller inventory endpoint file:

- `aap_workflow_project/inventory/controller.ini`

### Create Controller Resources

```bash
cd /home/sgallego/GIT/Ansible_2.7_install/aap_workflow_project
ansible-playbook -i inventory/controller.ini playbooks/create_controller_resources.yml
```

This creates organization, inventory, credentials, project, job templates, and the workflow template.

### Launch Workflow

From the AAP Controller UI:

1. Open the generated workflow template.
2. Launch it and complete the survey.
3. Choose `execution_playbook` value during launch (`install`, `backup`, `bundle`, `install_standalone_mcp`, `log_gathering`, `restore`, `uninstall`).

## Pre-Install Checklist

Before running install, confirm:

1. RHEL host is registered and has required repositories available.
2. Host has enough CPU/RAM/disk for your deployment size.
3. DNS and reverse DNS are configured (or use the script to set host details).
4. Required outbound access is available:
   - `access.redhat.com`
   - `access.cdn.redhat.com`
   - `console.redhat.com`
5. Credentials/tokens are ready:
  - RHSM username/password (same credentials generally used for Red Hat Login, CDN, and `registry.redhat.io`)
   - Red Hat offline token: https://access.redhat.com/management/api
   - Red Hat Automation Hub token: https://console.redhat.com/ansible/automation-hub/token
6. You have root/sudo access.
7. Time sync (chrony/ntp) is working.
8. FQDN resolves locally and in DNS.

## Usage

```bash
cd "/home/sgallego/GIT/Ansible_2.7_install"
chmod +x aap27_menu_installer.sh
./aap27_menu_installer.sh
```

The script is menuized and can be run in stages.

Recommended launch user is `admin` (with passwordless sudo); the script now escalates only privileged operations internally.

## Important Notes

- Disabling firewall and setting SELinux permissive is included because requested, but this is generally not recommended for production hardening.
- Installer execution (Step 10) requires a non-root SSH remote user; root is rejected by containerized installer preflight.
- Secrets are stored in a local env file:
  - `/home/admin/.aap27_install.env`
  - permissions `0600`
- Review generated `inventory-growth` before installation.
- This tool does not replace official Red Hat documentation.

## Helpful Links

- Red Hat login registration:
  - https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- Offline token:
  - https://access.redhat.com/management/api
- Remote Automation Hub token:
  - https://console.redhat.com/ansible/automation-hub/token

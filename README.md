# AAP 2.7-2 Menu Installer Helper

This folder contains a menu-driven bash helper for preparing and installing Red Hat Ansible Automation Platform (AAP) 2.7-2 containerized setup bundle on a single node.

## Files

- `aap27_menu_installer.sh`: Interactive dynamic menu script.
- `CHECKLIST.md`: Linked installation checklist and prerequisites.

## What This Tool Does

- Shows a checklist and readiness status with links.
- Provides a checklist help submenu with detailed prerequisite guidance.
- Performs common prework for AAP installs.
- Configures host identity requirements (FQDN, domain, `/etc/hosts`).
- Optionally disables firewall and sets SELinux to permissive for install workflows.
- Creates and configures an `admin` user with passwordless sudo and SSH keys.
- Captures required credentials/tokens and stores them in a local env file with restricted permissions.
- Downloads the AAP 2.7-2 containerized bundle to `/home/admin/Downloads/`.
- Extracts the bundle and updates `inventory-growth` with requested values.
- Runs installer command:
  - `ansible-playbook -i inventory-growth ansible.containerized_installer.install`

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
   - RHSM username/password
   - Red Hat offline token: https://access.redhat.com/management/api
   - Red Hat Automation Hub token: https://console.redhat.com/ansible/automation-hub/token
6. You have root/sudo access.
7. Time sync (chrony/ntp) is working.
8. FQDN resolves locally and in DNS.

## Usage

```bash
cd "/home/sgallego/GIT/Ansible_2.7_install"
chmod +x aap27_menu_installer.sh
sudo ./aap27_menu_installer.sh
```

The script is menuized and can be run in stages.

## Important Notes

- Disabling firewall and setting SELinux permissive is included because requested, but this is generally not recommended for production hardening.
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

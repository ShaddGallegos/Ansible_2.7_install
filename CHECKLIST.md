# AAP 2.7-2 Install Checklist

Use this checklist before running the installer or the AAP workflow project.

## Contents

- [Repository Automation Completed](#repository-automation-completed)
- [Accounts, Tokens, and Credentials](#accounts-tokens-and-credentials)
- [Host Readiness](#host-readiness)
- [Security and Access](#security-and-access)
- [Platform Components](#platform-components)
- [Execution Playbook Options](#execution-playbook-options)
- [Shell Menu Execution Command](#shell-menu-execution-command)
- [Ansible Workflow (Controller-Driven)](#ansible-workflow-controller-driven)

## Repository Automation Completed

- [x] Workflow prework now configures rootless podman for the runtime `remote_user` (not hardcoded `admin`).
- [x] Workflow prework now starts `user@<uid>` and waits for `/run/user/<uid>/bus` to avoid `systemctl --user` DBus failures.
- [x] Workflow install now validates `remote_user` matches `machine_credential_username` to fail early with actionable output.
- [x] Menu installer Step 10 now auto-prepares runtime user DBus session and enables `podman.socket` before running `ansible.containerized_installer`.
- [x] Menu installer Step 1 now auto-checks and auto-installs `podman` when missing (no prompt).
- [x] Workflow prework now configures both rootless and rootful `podman.socket` plus `DOCKER_HOST` compatibility for the installer user.
- [x] `~/.ansible/conf/env.yml` is the sole Vault-encrypted installer state source; updates are atomic and retain a mode-`0600` backup.
- [x] Target identity is derived from `AAP_SHORTNAME` and `AAP_DOMAIN_NAME` (for example, `aap.prod.spg`).
- [x] Full-install step arguments and failures propagate correctly, including forced target selection and `execution_playbook=install`.
- [x] Installer regression suite passes without contacting a real target host.

## Accounts, Tokens, and Credentials

- [ ] RHSM username/password
- [ ] RHSM account registration completed if needed: https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- [ ] Red Hat offline token
- [ ] Red Hat offline token generated: https://access.redhat.com/management/api
- [ ] Red Hat Remote Automation Hub token
- [ ] Red Hat Remote Automation Hub token generated: https://console.redhat.com/ansible/automation-hub/token

## Host Readiness

- [ ] Root or passwordless sudo access
- [ ] `admin` can run this script directly with passwordless sudo
- [ ] Install scope selected: `local` or `remote`
- [ ] For remote scope, remote admin bootstrap completed before target prework
- [ ] RHEL host meets CPU/RAM/storage requirements
- [ ] DNS and reverse DNS configured
- [ ] NTP/chrony synchronized
- [ ] FQDN set correctly
- [ ] `/etc/hosts` contains `<IP> <FQDN> aap`

## Security and Access

- [ ] `admin` user exists
- [ ] `admin` has passwordless sudo (`/etc/sudoers.d/admin`)
- [ ] SSH keys created for `admin`
- [ ] `admin` key copied to target node(s)
- [ ] Rootless podman is configured for installer `remote_user` (`/etc/subuid`, `/etc/subgid`, linger)
- [ ] `podman login registry.redhat.io` succeeds for installer `remote_user`

## Platform Components

- [ ] Local scope: bundle is under the invoking user's `Downloads` directory
- [ ] Remote scope: bundle is under `<ADMIN_HOME>/Downloads` on the target
- [ ] Bundle extracted
- [ ] `inventory-growth` updated
- [ ] Execution playbook selected and verified

## Execution Playbook Options

- [ ] install
- [ ] backup
- [ ] bundle
- [ ] install_standalone_mcp
- [ ] log_gathering
- [ ] restore
- [ ] uninstall

## Shell Menu Execution Command

```bash
ansible-playbook -i inventory-growth -u admin -e ansible_user=admin ansible.containerized_installer.install
```

## Ansible Workflow (Controller-Driven)

Use this path when launching installation through AAP Job Templates and Workflow Templates.

### Workflow Setup

- [ ] Change directory to the repository's `aap_workflow_project` directory
- [ ] Install required collections:

```bash
cd aap_workflow_project
ansible-galaxy collection install -r requirements.yml
```

- [ ] Update controller and credential values in `aap_workflow_project/group_vars/all.yml`
- [ ] Verify `aap_workflow_project/inventory/controller.ini`

### Create Controller Resources

```bash
cd aap_workflow_project
ansible-playbook -i inventory/controller.ini playbooks/create_controller_resources.yml
```

### Launch Workflow in AAP

- [ ] Open generated workflow template in AAP Controller
- [ ] Launch and complete survey values
- [ ] Set `remote_user` to a non-root SSH user (for example `admin`)
- [ ] Set `execution_playbook` to one of: `install`, `backup`, `bundle`, `install_standalone_mcp`, `log_gathering`, `restore`, `uninstall`

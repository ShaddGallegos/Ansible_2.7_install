# AAP 2.7-2 Install Checklist

Use this checklist before running the installer or the AAP workflow project.

## Repository Automation Completed

- [x] Workflow prework now configures rootless podman for the runtime `remote_user` (not hardcoded `admin`).
- [x] Workflow prework now starts `user@<uid>` and waits for `/run/user/<uid>/bus` to avoid `systemctl --user` DBus failures.
- [x] Workflow install now validates `remote_user` matches `machine_credential_username` to fail early with actionable output.
- [x] Menu installer Step 10 now auto-prepares runtime user DBus session and enables `podman.socket` before running `ansible.containerized_installer`.
- [x] Menu installer Step 1 now auto-checks and auto-installs `podman` when missing (no prompt).
- [x] Workflow prework now configures both rootless and rootful `podman.socket` plus `DOCKER_HOST` compatibility for the installer user.
- [x] Automation gateway readiness path now includes loopback-aware TLS behavior and better failure diagnostics.
- [x] Automation gateway service-node gather path now avoids restricted helper container execution by using exec in the running gateway container.
- [x] Automation gateway route update task now includes the required loop to prevent `item is undefined` failures.
- [x] Receptor signing key distribution now uses `slurp` plus `copy content` instead of `fetch` to avoid `/tmp/ansible.*` permission errors.

## Accounts, Tokens, and Credentials

- [ ] All sensitive values are stored in and loaded from `~/.ansible/conf/env.yml`
- [ ] Env file contains `AAP_REMOTE_IP`, `AAP_REMOTE_PASSWORD`, `AAP_REMOTE_BOOTSTRAP_USER`, `AAP_REMOTE_BOOTSTRAP_PASSWORD`, `RHSM_USERNAME`, `RHSM_PASSWORD`, and `RHSM_OFFLINE_TOKEN`
- [ ] RHSM username/password
- [ ] RHSM account registration completed if needed: https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- [ ] Red Hat offline token
- [ ] Red Hat offline token generated: https://access.redhat.com/management/api
- [ ] Offline token copied into installer env file as `RHSM_OFFLINE_TOKEN`
- [ ] Token verified against target bundle URL (HEAD/headers check)
- [ ] Token expiry/rotation date recorded
- [ ] Red Hat Remote Automation Hub token
- [ ] Red Hat Remote Automation Hub token generated: https://console.redhat.com/ansible/automation-hub/token
- [ ] Bundle download URL is the actual portal bundle link, not `/downloads/content/error?code=403`
- [ ] If testing the URL manually, quote it in the shell so `&` does not split the command
- [ ] Prefer `bearer` or `basic-auth` for bundle download auth; avoid relying on `basic-token`

### Token Troubleshooting

- [ ] If download fails with `mode=anonymous`, refresh token and credentials
- [ ] If MIME is `text/html`, confirm URL/token entitlement and regenerate token
- [ ] Ensure token is not truncated by shell quoting or copy/paste

## Host Readiness

- [ ] Root or passwordless sudo access
- [ ] `admin` can run this script directly with passwordless sudo
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

- [ ] AAP bundle downloaded to `/home/admin/Downloads/`
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

- [ ] Change directory to `/home/sgallego/GIT/Ansible_2.7_install/aap_workflow_project`
- [ ] Install required collections:

```bash
cd /home/sgallego/GIT/Ansible_2.7_install/aap_workflow_project
ansible-galaxy collection install -r requirements.yml
```

- [ ] Update controller and credential values in `aap_workflow_project/group_vars/all.yml`
- [ ] Verify `aap_workflow_project/inventory/controller.ini`

### Create Controller Resources

```bash
cd /home/sgallego/GIT/Ansible_2.7_install/aap_workflow_project
ansible-playbook -i inventory/controller.ini playbooks/create_controller_resources.yml
```

### Launch Workflow in AAP

- [ ] Open generated workflow template in AAP Controller
- [ ] Launch and complete survey values
- [ ] Set `remote_user` to a non-root SSH user (for example `admin`)
- [ ] Set `execution_playbook` to one of: `install`, `backup`, `bundle`, `install_standalone_mcp`, `log_gathering`, `restore`, `uninstall`

## Current Validation Step

- [ ] Re-run installer after latest receptor key-transfer patch and capture any next failing task.

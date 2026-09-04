# AAP 2.7-2 Menu Installer Helper

A concise helper repository and menu-driven installer for preparing and installing Red Hat Ansible Automation Platform (AAP) 2.7-2 (containerized) on a single node.

## Contents

- Files
- What This Tool Does
- Ansible Workflow (Controller-Driven)
- Pre-Install Checklist
- Usage
- Important Notes
- Development and Runtime Environments
- Helpful Links

## Files

- `aap27_installer.sh`: Interactive installer with documentation, scope,
  host-preparation, preflight, and full-install workflows.
- `lib/state.sh`: Allowlisted, non-executable installer state persistence.
- `lib/target.sh`: Local/remote target, SSH user, key, and inventory identity resolution.
- `roles/aap27_rootless_podman/`: Canonical Ansible implementation of rootless
  Podman user-bus, sub-ID, socket, migration, registry, and validation setup.
- `roles/aap27_preflight/`: Idempotent CPU, RAM, and disk-capacity validation.
- `aap_workflow_project/playbooks/fix_podman_user_bus.yml`: Standalone playbook
  entry point for the rootless Podman role.
- `aap_workflow_project/playbooks/preflight_resources.yml`: Standalone resource
  preflight entry point.
- `CHECKLIST.md`: Linked installation checklist and prerequisites.

## What This Tool Does

- Provides a documentation submenu for every maintained Markdown file in the
  repository.
- Keeps scope selection, host preparation, preflight, and AAP installation as
  separate top-level actions.
- Runs the same automated full-install workflow from menu option 5 and
  `--non-interactive`; both prompt for scope and remote target identity first.
- Provides `Reconfigure Env` to revisit install scope, target identity, admin
  password, Red Hat credentials and tokens, bundle URL, and Ansible verbosity.
  Pressing ENTER at an existing secret prompt keeps the current value without
  displaying it.
- Runs Step 1 preflight checks against the selected install target and installs
  `podman` during that target's prework step when missing.
- Performs common prework for AAP installs.
- Configures host identity requirements (FQDN, domain, `/etc/hosts`).
- The full-install pipeline disables firewalld and sets SELinux to permissive
  on the remote target before running the containerized installer.
- Creates and configures an `admin` user with passwordless sudo and SSH keys.
- Captures required credentials/tokens and stores them in a local env file with restricted permissions.
- Logs runtime installer user into `registry.redhat.io` using RHSM credentials.
- Configures rootless podman for runtime installer user (`/etc/subuid`, `/etc/subgid`, linger, user bus, `podman.socket`, migrate).
- Downloads the AAP bundle to the invoking user's `Downloads` directory for
  local scope or to `<ADMIN_HOME>/Downloads` on the target for remote scope.
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
- `roles/aap27_menu_installer/` - role-based equivalent of the shell menu steps
  (prework, host_identity, download_bundle, install), including the
  `ansible.containerized_installer` collection patches under its `files/`
  directory. Discovered automatically via `roles_path` in
  `aap_workflow_project/ansible.cfg`.
- `roles/aap27_defaults/` - shared/vaulted default variables
  (`vars/env.yml`, ansible-vault encrypted).

### Workflow Setup

1. Install required collection(s):

```bash
cd aap_workflow_project
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
cd aap_workflow_project
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
cd /path/to/Ansible_2.7_install
chmod +x aap27_installer.sh
./aap27_installer.sh
```

The script is menuized and can be run in stages.

Recommended launch user is `admin` (with passwordless sudo); the script now escalates only privileged operations internally.

## Install Scope Contract

`INSTALL_SCOPE=local` keeps preparation, bundle extraction, inventory mutation,
log cleanup, and nested installer execution on the installer node. Local bundle
state lives below the invoking user's `Downloads` directory.

`INSTALL_SCOPE=remote` keeps only controller state, credentials, inventory, and
an optional source bundle archive on the installer node. The remote admin is
bootstrapped first; packages, Podman, security settings, host identity, bundle
extraction, `inventory-growth`, compatibility fixes, logs, and nested installer
execution are owned by the remote `controller` host below `<ADMIN_HOME>`.

When the remote readiness marker, RHEL registration, repositories, or required
tools are missing, the installer uses `sshpass` with `root@<target>` to register
the host, enable its BaseOS and AppStream repositories, install bootstrap
packages, and configure the admin account. The one-time root password is
prompted directly and removed from state after successful bootstrap.

Remote order is significant: select remote scope, provision the remote admin,
then run preflight/prework and the remaining steps. Menu option 5 and
`--non-interactive` both enforce this fail-fast order:

1. Load the installation target from canonical state.
2. Bootstrap admin, RHEL repositories, and prerequisite packages.
3. Run dependency and resource preflight checks.
4. Prepare the host, disable firewalld, and set SELinux permissive.
5. Configure target host identity.
6. Capture credentials and tokens.
7. Download the bundle on the target.
8. Verify bundle extraction.
9. Prepare `inventory-growth`.
10. Run `ansible.containerized_installer.install`.

Target playbooks use `hosts: controller` so the local `installhost` inventory
entry is never mutated by remote preparation.

## Important Notes

- Disabling firewall and setting SELinux permissive is included because requested, but this is generally not recommended for production hardening.
- Installer execution (Step 10) requires a non-root SSH remote user; root is rejected by containerized installer preflight.
- Installer state is stored under the invoking user's home at
  `~/.ansible/conf/env.yml` (Ansible Vault encrypted, mode `0600`), shared across
  all local Ansible projects. This project's uppercase keys are stored under
  `ANSIBLE_2.7_INSTALL`; `templates/env.yml.example` is the canonical non-secret
  schema. Existing lowercase keys are promoted without replacing nonempty
  values. Updates are atomic and retain `env.yml.bak`. Decryption uses the vault password
  file at `~/.ansible/conf/.vaultpass.txt`, which is created once and reused
  (never recreated) across all projects and runs.
  The one-time remote root password is removed from state after bootstrap.
- Nested Ansible installer secrets are written to managed mode-`0600`
  extra-vars files and are never passed through process arguments.
- AAP is served on HTTPS port `443`. The installer also enables the rootless
  `aap27-http-redirect.service` on port `80`, which permanently redirects HTTP
  requests to the same host and path over HTTPS. When required, the redirect
  role persistently sets `net.ipv4.ip_unprivileged_port_start=80` so the admin
  user can bind the HTTP port without root.
- `aap_workflow_project/inventory/controller.ini` is generated locally and
  ignored by Git. Start from `controller.ini.example` or run the install-scope
  prompt to create it.
- Review generated `inventory-growth` before installation.
- This tool does not replace official Red Hat documentation.

## Development and Runtime Environments

- `.venv-aap27-runtime` is generated from `requirements-runtime.txt` and pins
  the installer execution path to supported `ansible-core` 2.16.
- `.venv-aap27` is the editor/development environment from
  `requirements-dev.txt`; VS Code uses it for `ansible-lint`.
- `lib/state.sh` owns canonical state and credential handling.
- `lib/target.sh` owns target resolution and generated controller inventory.
- `lib/workflow.sh` owns full-install sequencing and fail-fast behavior.
- `aap27_installer.sh` remains the CLI and interactive menu entrypoint.

## Helpful Links

- Red Hat login registration:
  - https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- Offline token:
  - https://access.redhat.com/management/api
- Remote Automation Hub token:
  - https://console.redhat.com/ansible/automation-hub/token

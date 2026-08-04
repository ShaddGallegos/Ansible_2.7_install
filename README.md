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

## Getting an Access Token

Use a Red Hat Offline Token for authenticated bundle downloads.

1. Sign in to Red Hat Customer Portal:
  - https://access.redhat.com
2. Open API management:
  - https://access.redhat.com/management/api
3. Create or copy your Offline Token.
4. Set it in your env file used by the installer:

```bash
RHSM_OFFLINE_TOKEN="<your_offline_token_here>"
```

Recommended related values in the same env file:

```bash
RHSM_USERNAME="<your_redhat_username>"
RHSM_PASSWORD="<your_redhat_password>"
```

If token auth fails, the installer may try other auth modes. If all fail, the download endpoint can return an HTML portal page instead of the tarball.

## Managing the Token

Use these practices to keep downloads reliable and secure:

1. Rotate the token periodically and after account/security changes.
2. Update the token in your env file immediately after rotation.
3. Keep env file permissions restrictive (`0600`) and owned by the runtime user.
4. Do not paste tokens into shell history, shared logs, or tickets.
5. If downloads start failing with HTML content or `mode=anonymous`, regenerate token and retry.

Quick verification from the target host (should not return HTML):

```bash
curl -sSIL -H "Authorization: Bearer $RHSM_OFFLINE_TOKEN" "$BUNDLE_URL"
```

Troubleshooting indicators:

- `downloaded archive failed validation` usually means non-archive content was fetched.
- `mime=text/html` means portal/login content was downloaded, not the bundle.
- `mode=anonymous` means authenticated methods failed and fallback did not have valid entitlement.

Bundle URL sanity check:

- Do not paste a Red Hat error-page URL such as `/downloads/content/error?code=403` into the installer.
- Use the actual bundle download URL from the Red Hat portal.
- If you test the URL manually in a shell, wrap it in single quotes so `&` is not treated as a background operator.
- For this bundle endpoint, prefer `bearer` or `basic-auth`; `basic-token` is not the preferred download path.

## Secret Handling

Keep all sensitive installer values in `~/.ansible/conf/env.yml` and let the installer read them back from there.

Typical values stored in the env file include:

- `AAP_REMOTE_IP`
- `AAP_REMOTE_PASSWORD`
- `AAP_REMOTE_BOOTSTRAP_USER`
- `AAP_REMOTE_BOOTSTRAP_PASSWORD`
- `RHSM_USERNAME`
- `RHSM_PASSWORD`
- `RHSM_OFFLINE_TOKEN`

The installer writes and loads these values through its env-file helpers, so they should not be hard coded in the script, docs, or shell command lines.

Example `~/.ansible/conf/env.yml` entries:

```bash
AAP_REMOTE_IP=192.168.122.190
AAP_REMOTE_PASSWORD=<remote_ssh_password>
AAP_REMOTE_BOOTSTRAP_USER=root
AAP_REMOTE_BOOTSTRAP_PASSWORD=<bootstrap_ssh_password>
RHSM_USERNAME=<redhat_username>
RHSM_PASSWORD=<redhat_password>
RHSM_OFFLINE_TOKEN=<rhsm_offline_token>
```

The installer will read those values back automatically once the env file is loaded.

Useful verification commands:

```bash
source ./aap27_menu_installer.sh
load_env

curl -sSIL -H "Authorization: Bearer ${RHSM_OFFLINE_TOKEN}" "${BUNDLE_URL}"

curl -sSIL -u "${RHSM_USERNAME}:${RHSM_PASSWORD}" "${BUNDLE_URL}"
```

If either verification command returns HTML or a Red Hat access error page, correct the bundle URL or entitlement before rerunning the installer.

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
- If the download URL resolves to an HTML error page instead of a tarball, fix the portal URL and entitlement before retrying.

## Recent Implementation Updates

The installer flow and collection patch overlay were updated to address multiple runtime blockers observed in real installs.

- Automation gateway startup/readiness hardening:
  - Added loopback-aware TLS validation behavior for readiness and gateway service registration paths.
  - Added faster readiness failure behavior with diagnostics and fallback probe logic.
- Automation gateway service registration fixes:
  - Added/adjusted gateway module defaults and CA-related environment handling.
  - Replaced helper transient container usage for service-node gathering with exec against the running gateway container to avoid OCI restriction failures.
  - Fixed route update task regression by restoring the missing routes loop.
- Receptor signing key distribution fix:
  - Replaced fetch-based key transfer in receptor signing tasks with slurp plus content-copy flow.
  - This avoids repeated permission failures in temporary ansible paths under /tmp during key distribution.

These changes are delivered through collection patch overlays in this repository and are applied into the extracted bundle before playbook execution.

## Helpful Links

- Red Hat login registration:
  - https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- Offline token:
  - https://access.redhat.com/management/api
- Remote Automation Hub token:
  - https://console.redhat.com/ansible/automation-hub/token

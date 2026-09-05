# Quickstart

Fastest path to running the AAP 2.7-2 menu installer.

## What it does

- Walks through prework, host identity, admin user, credentials, bundle
  download/extraction, and inventory setup for AAP 2.7 containerized install.
- Supports two install scopes: **local** (this host becomes the AAP node) and
  **remote** (a separate host is bootstrapped and installed over SSH).
- Can run the automated full-install workflow via `--non-interactive`, driven
  by env vars stored in `~/.ansible/conf/env.yml` (vault-encrypted, shared across
  runs). Identity values are always prompted before automation begins.

## Prerequisites

- RHEL-family host with `sudo` access.
- For remote scope: SSH reachability to the target host and its `root`
  password (used once through `sshpass` to register RHEL, enable repositories,
  install prerequisites, and bootstrap the `admin` account there).
- RHSM/Red Hat account credentials and tokens (see `CHECKLIST.md`).

## Common commands

Interactive menu (recommended for first run):

```bash
./aap27_installer.sh
```

Automated full install, using previously saved values in
`~/.ansible/conf/env.yml` (under this project's `Ansible_2.7_install:` section)
after prompting for scope and, for remote installs,
target IP, short hostname, and domain:

```bash
./aap27_installer.sh --non-interactive
```

Run the regression tests:

```bash
bash tests/test_aap27_menu_installer.sh
```

## Key runtime and state variables

| Variable | Purpose |
|---|---|
| `INSTALL_SCOPE` | `local` or `remote` |
| `ADMIN_USER` / `ADMIN_HOME` | Platform admin identity; defaults to `admin` and `/home/admin` |
| `AAP_CONTROLLER_IP` / `AAP_CONTROLLER_FQDN` | Remote target host (remote scope) |
| `AAP_REMOTE_ROOT_PASSWORD` | Runtime-only root SSH password used once to bootstrap `admin`; it is removed from installer state after use |
| `ADMIN_PASSWORD` | Password set for the `admin` account (local or remote) |
| `RHSM_USERNAME` / `RHSM_PASSWORD` | Red Hat account credentials |
| `RH_OFFLINE_TOKEN` / `RH_AH_TOKEN` | Offline API token / Automation Hub token |
| `BUNDLE_URL` | Override the default AAP setup bundle download URL |
| `AAP_MIN_CPU` / `AAP_MIN_RAM_GB` / `AAP_MIN_DISK_GB` | Preflight resource minimums |
| `AAP_APPLY_COLLECTION_PATCHES` | Apply the version-gated collection patch overlay; set `false` for unvalidated newer bundles |

## Next steps

See `README.md` for the full menu reference, and `CHECKLIST.md` for the
pre-install checklist.

## Example: Remote installer (Fedora installer -> RHEL target)

This is a quick example for running the installer from a Fedora-based installer node and installing AAP onto a separate RHEL 10 target (two VMs). The installer VM in my lab is Fedora 44 and the target is RHEL 10.

Requirements

- Installer OS: Fedora 44 (or a RHEL-family control host)
- Target OS: RHEL 10
- Storage: 50 GB available on target
- RAM: 17 GB
- CPUs: 4

High-level steps

1. On the installer (Fedora) VM clone this repository and change into it:

```bash
git clone https://github.com/ShaddGallegos/Ansible_2.7_install.git
cd Ansible_2.7_install
```

2. Download the AAP 2.7 containerized setup bundle into the installer user's `~/Downloads` directory. You can obtain the bundle from Red Hat:

- https://access.redhat.com/downloads/content/480/

3. Ensure the RHEL 10 VM is installed, reachable by SSH from the installer VM, and meets the requirements above.

4. Run the installer in non-interactive (automated) mode. The script will prompt for any missing identity/credential values and persist them to a vaulted env file on the installer node:

```bash
bash aap27_installer.sh --non-interactive
```

Notes about persisted state

- Installer values are saved in `~/.ansible/conf/env.yml` (Ansible Vault encrypted).
- The vault password file is created at `~/.ansible/conf/.vaultpass.txt`.

Typical variables the installer will prompt for

- `AAP_CONTROLLER_FQDN`
- `AAP_DOMAIN_NAME`
- `AAP_INSTALLER_SSH_KEY` (the script will create/pull this from `~/.ssh/` if missing)
- `AAP_INSTALLER_USER`
- `AAP_REMOTE_FQDN`
- `AAP_REMOTE_IP`
- `AAP_REMOTE_USER`
- `AAP_SHORTNAME`
- `INSTALL_SCOPE` (defaults to `remote`)
- `INVENTORY_GROWTH_USERNAME`
- `INVENTORY_GROWTH_PASSWORD`
- `RHSM_USERNAME`
- `RHSM_PASSWORD`
- `RH_AH_TOKEN` (Automation Hub token — https://console.redhat.com/ansible/automation-hub/token)
- `RH_OFFLINE_TOKEN` (Offline token — https://access.redhat.com/management/api)
- `ROOT_PASSWORD` (one-time root password for initial bootstrap, removed from state after use)

Try it out and let me know how it behaves in your environment.

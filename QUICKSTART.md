# Quickstart

Fastest path to running the AAP 2.7-2 menu installer.

## What it does

- Walks through prework, host identity, admin user, credentials, bundle
  download/extraction, and inventory setup for AAP 2.7 containerized install.
- Supports two install scopes: **local** (this host becomes the AAP node) and
  **remote** (a separate host is bootstrapped and installed over SSH).
- Can run fully unattended via `--non-interactive`, driven by env vars stored
  in `~/.aap27_install.env`.

## Prerequisites

- RHEL-family host with `sudo` access.
- For remote scope: SSH reachability to the target host and its `root`
  password (used once to bootstrap the `admin` account there).
- RHSM/Red Hat account credentials and tokens (see `CHECKLIST.md`).

## Common commands

Interactive menu (recommended for first run):

```bash
./aap27_menu_installer.sh
```

Non-interactive, using previously saved values in `~/.aap27_install.env`
(falls back to safe defaults / errors clearly on missing required secrets):

```bash
./aap27_menu_installer.sh --non-interactive
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

## Next steps

See `README.md` for the full menu reference, and `CHECKLIST.md` for the
pre-install checklist.

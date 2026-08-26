# Changelog

Notable changes to `aap27_installer.sh` and the surrounding project
structure. Newest first.

## 2026-08-14

### Repo structure
- Removed the superseded `fix_podman_user_bus.sh` compatibility helper and
  converted every remaining shell Podman call to the canonical Ansible
  playbook using a protected temporary extra-vars file.
- Added idempotent `aap27_preflight` role and standalone
  `playbooks/preflight_resources.yml`; role-driven and workflow prework now
  share CPU, RAM, and disk validation.
- Added production-profile ansible-lint and repository hygiene gates. Local
  generated inventory is ignored in favor of a generic tracked example;
  personal usernames, hostnames, paths, and private-network examples were
  removed from maintained sources.
- Made the shell platform admin identity configurable through validated
  `ADMIN_USER` and `ADMIN_HOME` values while retaining `admin` as the default.
- Removed the personal RHSM username default; unattended runs now require an
  explicitly supplied or previously stored account name.
- Parameterized admin users/homes/ownership across maintained roles and
  workflow playbooks. Secret-bearing inventory edits use `no_log`, and nested
  installer secrets now travel through mode-0600 extra-vars files instead of
  process arguments.
- Added reusable `aap27_rootless_podman` role as the canonical Ansible
  implementation for user-bus setup. Installer-role prework, workflow prework,
  and OCI remediation now invoke the shared role. Added standalone
  `playbooks/fix_podman_user_bus.yml` for direct use and removed the superseded
  Bash helper plus empty `vendor/` and `vendored/` scaffolds.
- Consolidated `aap_workflow_project/roles/aap27_menu_installer`,
  `collection_patches/`, and `defaults/` into a top-level `roles/` directory
  (`roles/aap27_menu_installer/`, `roles/aap27_defaults/`), matching the
  `roles_path = ./roles:../roles` already configured in
  `aap_workflow_project/ansible.cfg`.
- Fixed a pre-existing bug where the role's collection-patch path
  (`aap27_menu_installer_collection_patch_root`) resolved relative to
  `playbook_dir`, which never actually pointed at `collection_patches/` -
  patches were silently never applied. Now resolved via `{{ role_path }}`.
- Imported `automationcontroller`, `preflight`, and `receptor` patch roles
  from a 2.7-4 sibling checkout into a quarantined candidate directory. They
  are not part of the active 2.7-2 overlay.
- Added a patch manifest enforced by both Bash and Ansible. The installer now
  refuses to apply patches to an unvalidated bundle version.
- Removed a blanket `*` / `**/*` catch-all from `.gitignore` that was
  silently preventing any new file in the repo from being tracked.
- Added `.yamllint`, `.github/workflows/ci.yml` (opt-in via `AAP27_CI_ENABLED`
  repo variable or manual dispatch), and `tests/test_aap27_menu_installer.sh`.

### Script fixes and features
- Normalized remote inventory to use the saved controller FQDN as the host
  alias and the IP as `ansible_host`; rootless OCI remediation now targets the
  stable `controller` group instead of a hardcoded FQDN.
- Extracted state persistence and target resolution from the monolithic menu
  script into `lib/state.sh` and `lib/target.sh`. The main CLI sources these
  modules; function APIs and runtime behavior are unchanged.
- Fixed local installer state (Downloads, env file) being hardcoded to
  `/home/admin`, which doesn't exist on the local jump host when
  `INSTALL_SCOPE=remote`; now uses the invoking user's own `$HOME`.
- Added remote admin bootstrap (`provision_remote_admin_via_ssh`): logs in as
  `root@<remote host>` once to create/configure `admin` and `/home/admin`,
  then switches to `admin@<remote host>` (key-based) for everything after.
- Added `resolve_target_context()` / `get_install_target_fqdn()` /
  `get_install_target_host()` to fix inventory-growth generation targeting
  the local jump host instead of the actual remote AAP node.
- Fixed `get_preferred_remote_user()` incorrectly falling back to `$USER`
  instead of `admin` in remote scope.
- Added `extract_bundle()` auto-detection of the archive's real top-level
  directory name, fixing `inventory-growth not found` when a non-default
  `BUNDLE_URL` (different AAP version) is used.
- Added `preflight_resource_checks()`: CPU/RAM/disk minimums check, run
  locally or over SSH against the remote target.
- Added automated `--non-interactive` support (`ask_value`/`ask_yn` helpers,
  auto-detected when stdin isn't a tty), while retaining required prompts for
  install scope and remote target identity.
- Replaced executable `source`/`eval` state handling with strict key
  allowlisting, safe legacy parsing, and base64-encoded state writes. The
  one-time remote root password is no longer persisted after bootstrap.
- Fixed several spots where a failing step inside the interactive menu would
  kill the whole script (via `set -e`) instead of returning to the menu.
- Split the "Enter controller FQDN" prompt into separate short-hostname and
  domain prompts.
- Added a dedicated, explicit "Install Scope" prompt reachable from the main
  menu, the quick flow, and host-prep, always re-asking fresh.

#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "Bash is required to run this script."
  exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

BUNDLE_FILE="ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64.tar.gz"
BUNDLE_URL_DEFAULT="https://access.cdn.redhat.com/content/origin/files/sha256/5c/5c0e1834c1ae609ce840865b5aa279b5c5bde9118856b326f77cc5c8bf92d9af/ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64.tar.gz"
BUNDLE_DIR_NAME="ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_HOME="${ADMIN_HOME:-/home/${ADMIN_USER}}"
# Local installer state (Downloads/env file) lives under the invoking user's
# own home. The admin account/home is only guaranteed to exist locally when
# INSTALL_SCOPE=local; for INSTALL_SCOPE=remote, admin is created on the
# remote target host instead (see provision_remote_admin_via_ssh).
CONTROLLER_STATE_HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
CONTROLLER_STATE_HOME="${CONTROLLER_STATE_HOME:-/tmp}"
DOWNLOAD_DIR="${CONTROLLER_STATE_HOME}/Downloads"
ENV_FILE="${CONTROLLER_STATE_HOME}/.aap27_install.env"
INVENTORY_FILE="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"
DEFAULT_RHSM_USERNAME=""

# Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLU}[INFO]${NC} $*"; }
warn() { echo -e "${YEL}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR ]${NC} $*"; }
ok() { echo -e "${GRN}[ OK ]${NC} $*"; }

# Set true via --non-interactive/-y CLI flag, or auto-detected when stdin is
# not a tty (e.g. piped/cron/CI). No prompt in this script should block when true.
NONINTERACTIVE="${NONINTERACTIVE:-false}"

# Reads a value into $1 interactively, or uses default $3 (or existing env
# value of $1) without blocking when NONINTERACTIVE=true. Errors out if a
# required (no-default) value is missing in non-interactive mode.
ask_value() {
  local var_name="$1"
  local prompt="$2"
  local default_val="${3:-}"
  local -n target_ref="${var_name}"
  local current="${target_ref:-}"

  if [[ "${NONINTERACTIVE}" == "true" ]]; then
    if [[ -n "${current}" ]]; then
      return 0
    fi
    if [[ -n "${default_val}" ]]; then
      printf -v "${var_name}" '%s' "${default_val}"
      return 0
    fi
    err "Non-interactive mode: '${prompt}' has no value and no default. Set ${var_name} in ${ENV_FILE} and re-run."
    return 1
  fi

  read -r -p "${prompt}: " target_ref
  if [[ -z "${target_ref:-}" && -n "${default_val}" ]]; then
    target_ref="${default_val}"
  fi
}

# Yes/no confirmation. Returns 0 for yes, 1 for no. default_answer is "y" or "n".
ask_yn() {
  local prompt="$1"
  local default_answer="${2:-n}"
  local reply

  if [[ "${NONINTERACTIVE}" == "true" ]]; then
    log "Non-interactive: assuming '${default_answer}' for: ${prompt}"
    [[ "${default_answer}" =~ ^[Yy]$ ]]
    return $?
  fi

  read -r -p "${prompt} " reply
  reply="${reply:-${default_answer}}"
  [[ "${reply}" =~ ^[Yy]$ ]]
}

require_root() {
  if [[ ${EUID} -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    err "Run as root, or install sudo for non-root execution."
    exit 1
  fi
}

validate_admin_identity() {
  if [[ ! "${ADMIN_USER}" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
    err "ADMIN_USER='${ADMIN_USER}' is not a valid Linux user name."
    return 1
  fi
  if [[ "${ADMIN_HOME}" != /* ]]; then
    err "ADMIN_HOME must be an absolute path: ${ADMIN_HOME}"
    return 1
  fi
}

run_privileged() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

enforce_admin_home_ownership() {
  if id "${ADMIN_USER}" >/dev/null 2>&1; then
    run_privileged chown -R "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}"
  else
    warn "${ADMIN_USER} user does not exist yet; skipping ${ADMIN_HOME} ownership enforcement."
  fi
}

pause_enter() {
  if [[ "${NONINTERACTIVE}" == "true" ]]; then
    return 0
  fi
  read -r -p "Press ENTER to continue..." _unused
}

# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"

normalize_ansible_verbosity() {
  local raw_value="${1:-}"

  case "${raw_value}" in
    ""|0|none|NONE)
      printf ''
      ;;
    1|v|-v)
      printf '%s' '-v'
      ;;
    2|vv|-vv)
      printf '%s' '-vv'
      ;;
    3|vvv|-vvv)
      printf '%s' '-vvv'
      ;;
    *)
      printf ''
      ;;
  esac
}

configure_ansible_verbosity() {
  local choice selected_flag

  load_env
  selected_flag="$(normalize_ansible_verbosity "${ANSIBLE_VERBOSITY:-}")"

  clear
  cat <<EOF
Ansible Verbosity
=================
Current verbosity: ${selected_flag:-none}

1) none
2) -v
3) -vv
4) -vvv
0) Keep current
EOF

  read -r -p "Select verbosity level: " choice
  case "${choice}" in
    1) ANSIBLE_VERBOSITY="" ;;
    2) ANSIBLE_VERBOSITY="-v" ;;
    3) ANSIBLE_VERBOSITY="-vv" ;;
    4) ANSIBLE_VERBOSITY="-vvv" ;;
    0|"")
      log "Keeping current verbosity: ${selected_flag:-none}"
      return 0
      ;;
    *)
      warn "Invalid verbosity option. Keeping current value."
      return 0
      ;;
  esac

  save_env_kv "ANSIBLE_VERBOSITY" "${ANSIBLE_VERBOSITY}"
  ok "Ansible verbosity set to: ${ANSIBLE_VERBOSITY:-none}"
}

ensure_public_key_authorized() {
  local user_name="$1"
  local pubkey_file="$2"
  local user_home authorized_keys

  user_home="$(getent passwd "${user_name}" | cut -d: -f6 || true)"
  user_home="${user_home:-/home/${user_name}}"
  authorized_keys="${user_home}/.ssh/authorized_keys"

  [[ -f "${pubkey_file}" ]] || return 1

  run_privileged mkdir -p "${user_home}/.ssh"
  run_privileged touch "${authorized_keys}"
  run_privileged chmod 700 "${user_home}/.ssh"
  run_privileged chmod 600 "${authorized_keys}"

  if run_privileged grep -qxF "$(cat "${pubkey_file}")" "${authorized_keys}"; then
    return 0
  fi

  cat "${pubkey_file}" | run_privileged tee -a "${authorized_keys}" >/dev/null
  run_privileged chown -R "${user_name}:${user_name}" "${user_home}/.ssh"
}

ensure_controller_key_authorized_for_user() {
  local target_user="$1"
  local controller_key controller_pubkey controller_user

  controller_user="$(get_controller_user)"
  controller_key="$(get_controller_ssh_key)"
  controller_pubkey="${controller_key}.pub"

  if [[ ! -f "${controller_pubkey}" ]]; then
    warn "Controller public key not found for ${controller_user}: ${controller_pubkey}"
    return 1
  fi

  if ensure_public_key_authorized "${target_user}" "${controller_pubkey}"; then
    ok "Controller SSH public key authorized for ${target_user}."
    return 0
  fi

  warn "Unable to authorize controller SSH public key for ${target_user}."
  return 1
}

ensure_admin_user_exists() {
  if id "${ADMIN_USER}" >/dev/null 2>&1; then
    return 0
  fi

  warn "${ADMIN_USER} user does not exist; creating it now."
  if [[ -d "${ADMIN_HOME}" ]]; then
    run_privileged useradd -M -d "${ADMIN_HOME}" -s /bin/bash "${ADMIN_USER}"
  else
    run_privileged useradd -m -d "${ADMIN_HOME}" -s /bin/bash "${ADMIN_USER}"
  fi

  if [[ -d "${ADMIN_HOME}" ]]; then
    run_privileged chown "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}"
    run_privileged chmod 0750 "${ADMIN_HOME}" || true
  fi

  ok "${ADMIN_USER} user created."
}

run_rootless_podman_playbook() {
  local target_user="${1:-${ADMIN_USER}}"
  local registry_login="${2:-false}"
  local registry_user="${3:-}"
  local registry_pass="${4:-}"
  local inventory_file playbook_file extra_vars_file

  inventory_file="${SCRIPT_DIR}/aap_workflow_project/inventory/controller.ini"
  playbook_file="${SCRIPT_DIR}/aap_workflow_project/playbooks/fix_podman_user_bus.yml"

  if ! command -v ansible-playbook >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    err "ansible-playbook and jq are required for rootless Podman configuration."
    return 1
  fi
  if [[ ! -f "${inventory_file}" || ! -f "${playbook_file}" ]]; then
    err "Rootless Podman inventory or playbook is missing. Re-run install scope setup."
    return 1
  fi

  extra_vars_file="$(mktemp)"
  chmod 600 "${extra_vars_file}"
  jq -n \
    --arg deployment_user "${target_user}" \
    --arg registry_username "${registry_user}" \
    --arg registry_password "${registry_pass}" \
    --argjson registry_login "${registry_login}" \
    '{
      deployment_user: $deployment_user,
      registry_login: $registry_login,
      registry_username: $registry_username,
      registry_password: $registry_password
    }' > "${extra_vars_file}"

  if ! (
    cd "${SCRIPT_DIR}/aap_workflow_project"
    ANSIBLE_CONFIG="${SCRIPT_DIR}/aap_workflow_project/ansible.cfg" \
      ansible-playbook -i "${inventory_file}" "${playbook_file}" -e "@${extra_vars_file}"
  ); then
    rm -f "${extra_vars_file}"
    err "Rootless Podman Ansible role failed for ${target_user}."
    return 1
  fi

  rm -f "${extra_vars_file}"
  ok "Rootless Podman Ansible role completed for ${target_user}."
}

patch_containerized_installer_user_bus_task() {
  local install_dir="$1"
  local patch_root patch_manifest target_root relative_file source_file target_file runtime_tasks_file gateway_containers_file

  patch_root="${SCRIPT_DIR}/roles/aap27_menu_installer/files/collection_patches/ansible/containerized_installer"
  patch_manifest="${SCRIPT_DIR}/roles/aap27_menu_installer/files/collection_patches/manifest.conf"
  target_root="${install_dir}/collections/ansible_collections/ansible/containerized_installer"

  if [[ ! -d "${patch_root}" ]]; then
    warn "Collection patch root not found: ${patch_root}"
    return 0
  fi

  if [[ ! -f "${patch_manifest}" ]]; then
    err "Collection patch manifest not found: ${patch_manifest}"
    return 1
  fi

  if ! grep -qxF "supported_bundle_dir=${BUNDLE_DIR_NAME}" "${patch_manifest}"; then
    err "Collection patches are not validated for bundle directory '${BUNDLE_DIR_NAME}'."
    err "Supported bundle directories are listed in ${patch_manifest}."
    return 1
  fi

  while IFS= read -r relative_file; do
    source_file="${patch_root}/${relative_file}"
    target_file="${target_root}/${relative_file}"

    if [[ ! -f "${target_file}" ]]; then
      warn "Target collection file not found for patch: ${target_file}"
      continue
    fi

    if cmp -s "${source_file}" "${target_file}"; then
      log "INFO" "Collection patch already in place: ${relative_file}"
      continue
    fi

    cp "${source_file}" "${target_file}"
    ok "Applied collection patch: ${relative_file}"
  done < <(cd "${patch_root}" && find . -type f | sed 's#^./##' | sort)

  runtime_tasks_file="${target_root}/roles/common/tasks/main.yml"
  if [[ -f "${runtime_tasks_file}" ]] && grep -Fq 'podman_runtime: "{{ common_podman_runtime_effective | default(podman_runtime) }}"' "${runtime_tasks_file}"; then
    sed -i 's#podman_runtime: "{{ common_podman_runtime_effective | default(podman_runtime) }}"#podman_runtime: "{{ common_podman_runtime_effective }}"#g' "${runtime_tasks_file}"
    ok "Patched runtime template recursion guard in roles/common/tasks/main.yml"
  fi

  gateway_containers_file="${target_root}/roles/automationgateway/tasks/containers.yml"
  if [[ -f "${gateway_containers_file}" ]] && grep -Fq 'userns: keep-id' "${gateway_containers_file}"; then
    sed -i '/^[[:space:]]*user: "{{ ansible_user_uid }}"$/d' "${gateway_containers_file}"
    sed -i '/^[[:space:]]*userns: keep-id$/d' "${gateway_containers_file}"
    ok "Patched stale gateway keep-id settings in roles/automationgateway/tasks/containers.yml"
  fi
}

show_checklist() {
  clear
  cat <<'EOF'
AAP 2.7-2 INSTALLATION CHECKLIST
================================
Execute steps in the order shown:
 1. Run preflight dependency checks (Podman + core tools)
 2. Install required prework packages
 3. Configure firewalld/SELinux for installation mode
 4. Configure host identity (FQDN/domain + /etc/hosts)
 5. Provision admin user (NOPASSWD sudo + SSH key)
 6. Capture subscription credentials and tokens
 7. Download the AAP setup bundle
 8. Extract the setup bundle
 9. Update inventory-growth
10. Run the installer playbook

Credential and token references:
- RHSM account registration:
  https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- Red Hat offline token:
  https://access.redhat.com/management/api
- Remote Automation Hub token:
  https://console.redhat.com/ansible/automation-hub/token

Tip: enter step? for contextual guidance (example: 6?)
Launch as admin is supported; privileged operations use sudo internally.
EOF
  pause_enter
}

preflight_dependency_checks() {
  local -a required_cmds
  local -a missing_cmds

  required_cmds=(bash awk sed grep tar curl)
  missing_cmds=()

  log "Running Step 1 preflight dependency checks."

  for cmd in "${required_cmds[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing_cmds+=("${cmd}")
    fi
  done

  if (( ${#missing_cmds[@]} > 0 )); then
    warn "Missing basic tools: ${missing_cmds[*]}"
  else
    ok "Basic shell dependencies are present."
  fi

  if command -v podman >/dev/null 2>&1; then
    ok "podman is installed: $(podman --version 2>/dev/null || echo detected)"
  else
    warn "podman is not installed."
    if command -v dnf >/dev/null 2>&1; then
      log "Installing podman automatically via dnf."
      run_privileged dnf -y install podman || warn "Failed to install podman via dnf."
    else
      warn "dnf not found; install podman manually before Step 10."
    fi
  fi

  preflight_resource_checks

  if command -v podman >/dev/null 2>&1; then
    ok "Preflight complete: podman available."
  else
    warn "Preflight complete with warnings: podman still missing."
  fi
}

preflight_resource_checks() {
  local min_cpu min_ram_gb min_disk_gb
  local cpu_count ram_kb ram_gb disk_avail_gb

  load_env
  min_cpu="${AAP_MIN_CPU:-4}"
  min_ram_gb="${AAP_MIN_RAM_GB:-16}"
  min_disk_gb="${AAP_MIN_DISK_GB:-40}"

  resolve_target_context

  if [[ "${TARGET_SCOPE}" == "remote" ]]; then
    if [[ -z "${TARGET_HOST}" ]]; then
      warn "INSTALL_SCOPE=remote but no controller host recorded; skipping remote CPU/RAM/storage checks."
      return 0
    fi
    if [[ ! -f "${TARGET_SSH_KEY}" ]]; then
      warn "No controller SSH key found (${TARGET_SSH_KEY}); run Step 6 (admin user) first. Skipping remote CPU/RAM/storage checks."
      return 0
    fi
    if [[ "${TARGET_REACHABLE}" != "true" ]]; then
      warn "Unable to reach ${TARGET_DESC} via SSH; skipping remote CPU/RAM/storage checks."
      return 0
    fi

    cpu_count="$(remote_target_exec 'nproc' 2>/dev/null)"
    ram_kb="$(remote_target_exec "awk '/MemTotal/{print \$2}' /proc/meminfo" 2>/dev/null)"
    disk_avail_gb="$(remote_target_exec "df -BG / | awk 'NR==2{print \$4}' | tr -d 'G'" 2>/dev/null)"
  else
    cpu_count="$(nproc 2>/dev/null)"
    ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
    disk_avail_gb="$(df -BG / 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')"
  fi

  [[ "${cpu_count}" =~ ^[0-9]+$ ]] || cpu_count=0
  [[ "${ram_kb}" =~ ^[0-9]+$ ]] || ram_kb=0
  [[ "${disk_avail_gb}" =~ ^[0-9]+$ ]] || disk_avail_gb=0
  ram_gb=$(( ram_kb / 1024 / 1024 ))

  log "Checking CPU/RAM/storage requirements on ${TARGET_DESC} (minimums: ${min_cpu} vCPU, ${min_ram_gb} GB RAM, ${min_disk_gb} GB free disk)."

  if (( cpu_count >= min_cpu )); then
    ok "CPU: ${cpu_count} vCPU(s) detected (minimum ${min_cpu})."
  else
    warn "CPU: ${cpu_count} vCPU(s) detected; below recommended minimum of ${min_cpu}."
  fi

  if (( ram_gb >= min_ram_gb )); then
    ok "RAM: ${ram_gb} GB detected (minimum ${min_ram_gb} GB)."
  else
    warn "RAM: ${ram_gb} GB detected; below recommended minimum of ${min_ram_gb} GB."
  fi

  if (( disk_avail_gb >= min_disk_gb )); then
    ok "Storage: ${disk_avail_gb} GB free on / (minimum ${min_disk_gb} GB)."
  else
    warn "Storage: ${disk_avail_gb} GB free on /; below recommended minimum of ${min_disk_gb} GB."
  fi
}

show_step_help() {
  local step="$1"
  clear
  case "$step" in
    2)
      cat <<'EOF'
Step 2 - Prework Packages
-------------------------
    - Installs baseline packages required by the setup flow.
    - Enables and starts sshd.
    - Intended for RHEL hosts using dnf.
EOF
      ;;
    3)
      cat <<'EOF'
Step 3 - Firewall and SELinux
-----------------------------
- Disables firewalld.
- Sets SELinux runtime and configuration to permissive.
- Appropriate for installation troubleshooting, not final hardened posture.
EOF
      ;;
    4)
      cat <<'EOF'
Step 4 - Host Identity
----------------------
- Sets or updates system FQDN.
- Derives domain value from hostname -d when available.
- Ensures /etc/hosts entry: <system_ip> <fqdn> aap
EOF
      ;;
    5)
      cat <<'EOF'
Step 5 - Admin User
-------------------
- Creates admin user if missing.
- Configures passwordless sudo for the configured platform admin user.
- Generates an Ed25519 key under the configured platform admin home.
- Attempts ssh-copy-id to the configured platform admin user.
EOF
      ;;
    6)
      cat <<'EOF'
Step 6 - Credentials and Tokens
-------------------------------
Credential key synopsis:
- RHSM_USERNAME:
  Your Red Hat account username (email or username).
  Common aliases/operators may use for this same identity:
  Red Hat Login, Red Hat CDN username, registry.redhat.io username, console.redhat.com username.

- RHSM_PASSWORD:
  Password for the same Red Hat account above.
  Common aliases:
  Red Hat Login password, Red Hat CDN password, registry.redhat.io password, console.redhat.com password.

- RH_OFFLINE_TOKEN:
  API/offline token from access.redhat.com used for automated authenticated downloads.

- RH_AH_TOKEN:
  Token for Red Hat Remote Automation Hub access from console.redhat.com.

RHSM account registration:
https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1

Offline token:
https://access.redhat.com/management/api

Remote Automation Hub token:
https://console.redhat.com/ansible/automation-hub/token

Captured values are stored under the invoking user's home (mode 0600).
EOF
      ;;
    7)
      cat <<'EOF'
Step 7 - Download Bundle
------------------------
- Downloads the bundle to the invoking user's Downloads directory.
- Uses file name:
  ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64.tar.gz
EOF
      ;;
    8)
      cat <<'EOF'
Step 8 - Extract Bundle
-----------------------
- Extracts the tarball under the invoking user's Downloads directory.
- Expected extraction directory:
  <controller-state-home>/Downloads/<bundle-directory>
EOF
      ;;
    9)
      cat <<'EOF'
Step 9 - Modify inventory-growth
--------------------------------
- Updates:
  aap.example.test -> ansible_host=<target-address> ansible_user=<platform-admin-user> ansible_ssh_private_key_file=<controller-key>
  password=<set your own> -> password={{ admin_password }}
  collections=false -> collections=true
- Ensures [all:vars] includes admin/postgres/registry values.
EOF
      ;;
    10)
      cat <<'EOF'
Step 10 - Run Installer
-----------------------
    Execution submenu supports these playbooks:
    - ansible.containerized_installer.install
    - ansible.containerized_installer.backup
    - ansible.containerized_installer.bundle
    - ansible.containerized_installer.install_standalone_mcp
    - ansible.containerized_installer.log_gathering
    - ansible.containerized_installer.restore
    - ansible.containerized_installer.uninstall

Execution directory:
<controller-state-home>/Downloads/<bundle-directory>
EOF
      ;;
    *)
      cat <<'EOF'
No help is defined for that step.
Use 2? through 10? from the main menu.
EOF
      ;;
  esac
  pause_enter
}

read_secret_prompt() {
  local var_name="$1"
  local prompt="$2"
  local value

  if [[ "${NONINTERACTIVE}" == "true" ]]; then
    err "Non-interactive mode: '${prompt}' requires a secret with no safe default. Set ${var_name} in ${ENV_FILE} and re-run."
    return 1
  fi

  read -r -s -p "${prompt}: " value
  echo
  printf -v "${var_name}" '%s' "${value}"
}

prework_packages() {
  local packages=(
    sudo
    openssh-server
    openssh-clients
    sshpass
    policycoreutils-python-utils
    tar
    gzip
    curl
    jq
    rsync
    podman
    python3
    python3-pip
    ansible-core
  )

  log "Proposed prework packages:"
  printf ' - %s\n' "${packages[@]}"
  if ! ask_yn "Proceed with package installation? [Y/n]:" "y"; then
    warn "Prework package installation skipped by operator."
    return 0
  fi

  log "Installing required prework packages."

  if command -v dnf >/dev/null 2>&1; then
    run_privileged dnf -y install "${packages[@]}" || warn "One or more packages failed to install."
  else
    warn "dnf not found; package installation skipped."
  fi

  run_privileged systemctl enable --now sshd || warn "Unable to enable/start sshd."
  ok "Prework package installation step completed."
}

disable_firewall_selinux() {
  cat <<'EOF'
Planned system changes:
- Disable and stop firewalld service
- Set SELinux runtime mode to permissive (setenforce 0)
- Set SELINUX=permissive in /etc/selinux/config
EOF
  if ! ask_yn "Apply these installation-mode security changes? [y/N]:" "n"; then
    warn "Firewall/SELinux changes skipped by operator."
    return 0
  fi

  log "Applying installation-mode firewall and SELinux settings."

  if run_privileged systemctl is-active --quiet firewalld; then
    run_privileged systemctl disable --now firewalld
  else
    warn "firewalld is already stopped or not installed."
  fi

  if command -v setenforce >/dev/null 2>&1; then
    run_privileged setenforce 0 || warn "Unable to set SELinux runtime mode to permissive."
  fi

  if [[ -f /etc/selinux/config ]]; then
    run_privileged sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
  fi

  ok "Firewall and SELinux settings applied."
}

set_fqdn_and_hosts() {
  local current_fqdn current_domain target_fqdn target_domain system_ip hosts_alias

  load_env
  current_fqdn="$(hostname -f 2>/dev/null || true)"
  current_domain="$(hostname -d 2>/dev/null || true)"

  log "Detected FQDN: ${current_fqdn:-<not-set>}"
  log "Detected domain: ${current_domain:-<not-set>}"

  if [[ -z "${current_fqdn}" || "${current_fqdn}" == "localhost" || "${current_fqdn}" == "localhost.localdomain" ]]; then
    target_fqdn=""
    ask_value target_fqdn "Enter target system FQDN (example: aap.example.com)" || return 1
    if [[ -z "${target_fqdn}" ]]; then
      err "FQDN is required."
      return 1
    fi
  else
    if ask_yn "Use detected FQDN '${current_fqdn}'? [Y/n]:" "y"; then
      target_fqdn="${current_fqdn}"
    else
      target_fqdn=""
      ask_value target_fqdn "Enter target system FQDN" || return 1
      if [[ -z "${target_fqdn}" ]]; then
        err "FQDN is required."
        return 1
      fi
    fi
  fi

  target_domain="${target_fqdn#*.}"
  if [[ "${target_domain}" == "${target_fqdn}" ]]; then
    target_domain=""
  fi

  system_ip="$(hostname -I | awk '{print $1}')"
  if [[ -z "${system_ip}" ]]; then
    err "Unable to determine system IP for /etc/hosts update."
    return 1
  fi

  # This local host only owns the 'aap' alias when it IS the AAP node
  # (INSTALL_SCOPE=local); for remote scope, 'aap' refers to the remote target.
  hosts_alias=""
  if [[ "${INSTALL_SCOPE:-}" != "remote" ]]; then
    hosts_alias=" aap"
  fi

  cat <<EOF
Planned host identity changes:
- hostnamectl set-hostname ${target_fqdn}
- /etc/hosts entry ensured: ${system_ip} ${target_fqdn}${hosts_alias}
- domain value to apply: ${target_domain:-<none>}
EOF
  if ! ask_yn "Apply these host identity changes? [y/N]:" "n"; then
    warn "Host identity changes skipped by operator."
    return 0
  fi

  run_privileged hostnamectl set-hostname "${target_fqdn}"

  if [[ -n "${target_domain}" ]]; then
    if command -v domainname >/dev/null 2>&1; then
      run_privileged domainname "${target_domain}" || warn "Unable to set domainname value."
    fi
    if [[ -f /etc/sysconfig/network ]]; then
      if grep -q '^DOMAINNAME=' /etc/sysconfig/network; then
        run_privileged sed -i "s/^DOMAINNAME=.*/DOMAINNAME=${target_domain}/" /etc/sysconfig/network
      else
        printf 'DOMAINNAME=%s\n' "${target_domain}" | run_privileged tee -a /etc/sysconfig/network >/dev/null
      fi
    fi
  else
    warn "No domain component detected in FQDN; domain-specific updates skipped."
  fi

  run_privileged sed -i "/[[:space:]]${target_fqdn//./\\.}[[:space:]]/d" /etc/hosts || true
  # Always drop any stray 'aap' alias on this host; re-add it only if this
  # host is actually the AAP node (local scope). Prevents a leftover local
  # 'aap' alias from shadowing the real remote target's hostname.
  run_privileged sed -i "/[[:space:]]aap$/d" /etc/hosts || true
  printf '%s %s%s\n' "${system_ip}" "${target_fqdn}" "${hosts_alias}" | run_privileged tee -a /etc/hosts >/dev/null

  ok "Host identity updated. FQDN=${target_fqdn}, domain=${target_domain:-<unset>}."
}

provision_remote_admin_via_ssh() {
  local remote_host local_key local_pub
  local root_password admin_password pubkey_b64 adminpw_b64 adminuser_b64 adminhome_b64 payload

  load_env
  remote_host="${AAP_CONTROLLER_IP:-${AAP_CONTROLLER_FQDN:-}}"
  if [[ -z "${remote_host}" ]]; then
    err "No remote host recorded. Re-run Installation Mode selection (option 2, Remote) first."
    return 1
  fi

  local_key="${CONTROLLER_STATE_HOME}/.ssh/id_ed25519"
  local_pub="${local_key}.pub"

  if [[ ! -f "${local_key}" ]]; then
    log "Generating local SSH keypair to reach ${ADMIN_USER}@${remote_host}."
    mkdir -p "${CONTROLLER_STATE_HOME}/.ssh"
    chmod 700 "${CONTROLLER_STATE_HOME}/.ssh"
    ssh-keygen -t ed25519 -N "" -f "${local_key}" >/dev/null
    chmod 600 "${local_key}"
    chmod 644 "${local_pub}"
  fi

    if ssh -i "${local_key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes -o ConnectTimeout=5 "${ADMIN_USER}@${remote_host}" 'true' >/dev/null 2>&1; then
    delete_env_key "AAP_REMOTE_ROOT_PASSWORD"
    unset AAP_REMOTE_ROOT_PASSWORD
    save_env_kv "AAP_CONTROLLER_SSH_KEY" "${local_key}"
    ok "Remote admin key access already works on ${ADMIN_USER}@${remote_host}; bootstrap skipped."
    return 0
  fi

  if ! command -v sshpass >/dev/null 2>&1; then
    err "sshpass is required to bootstrap the remote admin user; install it and re-run."
    return 1
  fi

  if [[ -n "${AAP_REMOTE_ROOT_PASSWORD:-}" ]]; then
    root_password="${AAP_REMOTE_ROOT_PASSWORD}"
    log "Using provided root SSH password for root@${remote_host}."
  else
    read_secret_prompt root_password "Enter root SSH password for root@${remote_host} (used once to bootstrap admin)"
  fi

  if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
    admin_password="${ADMIN_PASSWORD}"
    log "Reusing saved admin password from ${ENV_FILE}."
  else
    read_secret_prompt admin_password "Enter password to set for remote admin user"
    save_env_kv "ADMIN_PASSWORD" "${admin_password}"
  fi

  pubkey_b64="$(base64 -w0 "${local_pub}")"
  adminpw_b64="$(printf '%s' "${admin_password}" | base64 -w0)"
  adminuser_b64="$(printf '%s' "${ADMIN_USER}" | base64 -w0)"
  adminhome_b64="$(printf '%s' "${ADMIN_HOME}" | base64 -w0)"

  # Values are base64'd locally and decoded remotely to avoid quoting issues over ssh.
  payload=$(cat <<REMOTE
set -e
PUBKEY="\$(printf '%s' '${pubkey_b64}' | base64 -d)"
ADMINPW="\$(printf '%s' '${adminpw_b64}' | base64 -d)"
ADMINUSER="\$(printf '%s' '${adminuser_b64}' | base64 -d)"
ADMINHOME="\$(printf '%s' '${adminhome_b64}' | base64 -d)"
id "\${ADMINUSER}" >/dev/null 2>&1 || useradd -m -d "\${ADMINHOME}" -s /bin/bash "\${ADMINUSER}"
mkdir -p "\${ADMINHOME}/.ssh"
touch "\${ADMINHOME}/.ssh/authorized_keys"
grep -qxF "\${PUBKEY}" "\${ADMINHOME}/.ssh/authorized_keys" || echo "\${PUBKEY}" >> "\${ADMINHOME}/.ssh/authorized_keys"
chown -R "\${ADMINUSER}:\${ADMINUSER}" "\${ADMINHOME}"
chmod 750 "\${ADMINHOME}"
chmod 700 "\${ADMINHOME}/.ssh"
chmod 600 "\${ADMINHOME}/.ssh/authorized_keys"
printf '%s:%s\n' "\${ADMINUSER}" "\${ADMINPW}" | chpasswd
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "\${ADMINUSER}" > "/etc/sudoers.d/\${ADMINUSER}"
chmod 0440 "/etc/sudoers.d/\${ADMINUSER}"
REMOTE
)

  # Step 1: log in as root@remote (password auth) to create/configure admin, then disconnect.
  log "Connecting to root@${remote_host} to create and configure the admin user."
  if ! printf '%s\n' "${payload}" | \
      sshpass -p "${root_password}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${remote_host}" 'bash -s'; then
    err "Failed to provision admin user on ${remote_host} as root."
    return 1
  fi
  ok "admin user bootstrapped on ${remote_host}; root@${remote_host} session closed."

  # Step 2: re-connect as the configured admin user (key auth).
  log "Re-connecting as ${ADMIN_USER}@${remote_host} to confirm key-based access."
  if ! ssh -i "${local_key}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes "${ADMIN_USER}@${remote_host}" 'true'; then
    err "${ADMIN_USER}@${remote_host} key-based login failed after bootstrap."
    return 1
  fi
  delete_env_key "AAP_REMOTE_ROOT_PASSWORD"
  unset AAP_REMOTE_ROOT_PASSWORD root_password
  save_env_kv "AAP_CONTROLLER_SSH_KEY" "${local_key}"
  ok "Remote admin user and SSH key authorized on ${ADMIN_USER}@${remote_host}."
}

setup_admin_user() {
  local host_fqdn admin_password

  load_env

  if [[ "${INSTALL_SCOPE:-}" == "remote" ]]; then
    provision_remote_admin_via_ssh
    return $?
  fi

  ensure_admin_user_exists
  log "${ADMIN_USER} user is present."

  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${ADMIN_USER}" | run_privileged tee "/etc/sudoers.d/${ADMIN_USER}" >/dev/null
  run_privileged chmod 0440 "/etc/sudoers.d/${ADMIN_USER}"

  # Ensure admin home and SSH directory are writable by admin before key operations.
  if [[ -d "${ADMIN_HOME}" ]]; then
    run_privileged chown "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}"
    chmod 0750 "${ADMIN_HOME}" || true
  fi

  mkdir -p "${ADMIN_HOME}/.ssh"
  run_privileged chown "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.ssh"
  chmod 700 "${ADMIN_HOME}/.ssh"

  if [[ ! -f "${ADMIN_HOME}/.ssh/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -N "" -f "${ADMIN_HOME}/.ssh/id_ed25519" >/dev/null
    run_privileged chown "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.ssh/id_ed25519" "${ADMIN_HOME}/.ssh/id_ed25519.pub"
    chmod 600 "${ADMIN_HOME}/.ssh/id_ed25519"
    chmod 644 "${ADMIN_HOME}/.ssh/id_ed25519.pub"
  fi

  if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
    admin_password="${ADMIN_PASSWORD}"
    log "Reusing saved admin password from ${ENV_FILE}."
  else
    read_secret_prompt admin_password "Enter password for admin user"
    printf '%s:%s\n' "${ADMIN_USER}" "${admin_password}" | run_privileged chpasswd
    save_env_kv "ADMIN_PASSWORD" "${admin_password}"
  fi

  host_fqdn="$(hostname -f 2>/dev/null || hostname)"

  if ensure_public_key_authorized "${ADMIN_USER}" "${ADMIN_HOME}/.ssh/id_ed25519.pub"; then
    ok "admin SSH public key already authorized locally."
  elif command -v sshpass >/dev/null 2>&1; then
    log "Copying admin SSH key to ${ADMIN_USER}@${host_fqdn}."
    sshpass -p "${admin_password}" ssh-copy-id \
      -o StrictHostKeyChecking=no \
      -i "${ADMIN_HOME}/.ssh/id_ed25519.pub" \
      "${ADMIN_USER}@${host_fqdn}" || warn "ssh-copy-id failed; continuing."
  else
    warn "sshpass is not installed; skipping ssh-copy-id."
  fi

  ensure_controller_key_authorized_for_user "${ADMIN_USER}" || true

  run_privileged chown -R "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.ssh"
  run_rootless_podman_playbook "${ADMIN_USER}" false
  ok "admin user setup complete."
}

capture_credentials() {
  local rhsm_user rhsm_pass offline_token hub_token bundle_url

  load_env

  cat <<'EOF'
Credential key synopsis:
- RHSM_USERNAME:
  Red Hat account username (email or username).
  Same credentials are commonly used for Red Hat Login, CDN, registry.redhat.io, and console.redhat.com.
- RHSM_PASSWORD:
  Password for the same Red Hat account above.
- RH_OFFLINE_TOKEN:
  Offline/API token from access.redhat.com.
- RH_AH_TOKEN:
  Token from console.redhat.com for Remote Automation Hub access.

Reference links for account and token retrieval:
- Red Hat Login registration:
  https://www.redhat.com/wapps/ugc/register.html?_flowId=register-flow&_flowExecutionKey=e1s1
- Red Hat offline token:
  https://access.redhat.com/management/api
- Red Hat Remote Automation Hub token:
  https://console.redhat.com/ansible/automation-hub/token
EOF

  if [[ -n "${RHSM_USERNAME:-}" ]]; then
    rhsm_user="${RHSM_USERNAME}"
    log "Reusing saved RHSM username from ${ENV_FILE}."
  else
    rhsm_user=""
    ask_value rhsm_user "Enter RHSM_USERNAME (Red Hat Login/CDN/registry/console username)" "${DEFAULT_RHSM_USERNAME}" || return 1
  fi

  if [[ -n "${RHSM_PASSWORD:-}" ]]; then
    rhsm_pass="${RHSM_PASSWORD}"
    log "Reusing saved RHSM password from ${ENV_FILE}."
  else
    read_secret_prompt rhsm_pass "Enter RHSM_PASSWORD (Red Hat Login/CDN/registry/console password)"
  fi

  if [[ -n "${RH_OFFLINE_TOKEN:-}" ]]; then
    offline_token="${RH_OFFLINE_TOKEN}"
    log "Reusing saved offline token from ${ENV_FILE}."
  else
    read_secret_prompt offline_token "Enter RH_OFFLINE_TOKEN (from access.redhat.com)"
  fi

  if [[ -n "${RH_AH_TOKEN:-}" ]]; then
    hub_token="${RH_AH_TOKEN}"
    log "Reusing saved Remote Automation Hub token from ${ENV_FILE}."
  else
    read_secret_prompt hub_token "Enter RH_AH_TOKEN (Remote Automation Hub token)"
  fi

  if [[ -n "${BUNDLE_URL:-}" ]]; then
    bundle_url="${BUNDLE_URL}"
    log "Reusing saved bundle URL from ${ENV_FILE}."
  elif [[ "${NONINTERACTIVE}" == "true" ]]; then
    bundle_url=""
    log "Non-interactive: using default bundle URL."
  else
    read -r -p "Bundle URL [ENTER for default]: " bundle_url
  fi

  save_env_kv "RHSM_USERNAME" "${rhsm_user}"
  save_env_kv "RHSM_PASSWORD" "${rhsm_pass}"
  save_env_kv "CDN_USERNAME" "${rhsm_user}"
  save_env_kv "CDN_PASSWORD" "${rhsm_pass}"
  save_env_kv "REDHAT_USERNAME" "${rhsm_user}"
  save_env_kv "REDHAT_PASSWORD" "${rhsm_pass}"
  save_env_kv "CONSOLE_USERNAME" "${rhsm_user}"
  save_env_kv "CONSOLE_PASSWORD" "${rhsm_pass}"
  save_env_kv "RH_OFFLINE_TOKEN" "${offline_token}"
  save_env_kv "RH_AH_TOKEN" "${hub_token}"
  save_env_kv "BUNDLE_URL" "${bundle_url:-$BUNDLE_URL_DEFAULT}"

  run_rootless_podman_playbook "${ADMIN_USER}" true "${rhsm_user}" "${rhsm_pass}"

  ok "Credentials and tokens ensured in ${ENV_FILE} (mode 600)."
}

download_bundle() {
  local retry_depth="${1:-0}"
  load_env
  ensure_registry_credentials

  local bundle_url tmp_bundle file_type sudo_user_home candidate controller_user controller_home retry_creds
  local -a curl_args local_candidates
  bundle_url="${BUNDLE_URL:-$BUNDLE_URL_DEFAULT}"
  tmp_bundle="${DOWNLOAD_DIR}/${BUNDLE_FILE}.tmp"
  controller_user="$(get_controller_user)"
  controller_home="$(get_user_home "${controller_user}")"

  mkdir -p "${DOWNLOAD_DIR}"
  if id "${controller_user}" >/dev/null 2>&1; then
    chown "${controller_user}:${controller_user}" "${DOWNLOAD_DIR}" 2>/dev/null || true
  fi

  # Prefer an existing local bundle in ~/Downloads before remote download.
  local_candidates=(
    "${DOWNLOAD_DIR}/${BUNDLE_FILE}"
    "${controller_home}/Downloads/${BUNDLE_FILE}"
    "${HOME}/Downloads/${BUNDLE_FILE}"
  )

  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo_user_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6 || true)"
    if [[ -n "${sudo_user_home}" ]]; then
      local_candidates+=("${sudo_user_home}/Downloads/${BUNDLE_FILE}")
    fi
  fi

  for candidate in "${local_candidates[@]}"; do
    [[ -f "${candidate}" ]] || continue
    if tar -tzf "${candidate}" >/dev/null 2>&1 || tar -tf "${candidate}" >/dev/null 2>&1; then
      if [[ "${candidate}" != "${DOWNLOAD_DIR}/${BUNDLE_FILE}" ]]; then
        cp -f "${candidate}" "${DOWNLOAD_DIR}/${BUNDLE_FILE}"
      fi
      if id "${controller_user}" >/dev/null 2>&1; then
        chown "${controller_user}:${controller_user}" "${DOWNLOAD_DIR}/${BUNDLE_FILE}" 2>/dev/null || true
      fi
      ok "Using existing local bundle file: ${candidate}"
      return 0
    fi
  done

  log "Downloading setup bundle to ${DOWNLOAD_DIR}/${BUNDLE_FILE}."

  curl_args=(
    -L
    --fail
    --retry
    3
    --retry-delay
    2
    --connect-timeout
    20
    -o
    "${tmp_bundle}"
    "${bundle_url}"
  )

  # Prefer authenticated fetch to avoid CDN login redirects being saved as HTML.
  if [[ -n "${RHSM_USERNAME:-}" && -n "${RHSM_PASSWORD:-}" ]]; then
    curl_args+=(--user "${RHSM_USERNAME}:${RHSM_PASSWORD}")
  fi

  if [[ -n "${RH_OFFLINE_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${RH_OFFLINE_TOKEN}")
  fi

  if ! curl "${curl_args[@]}"; then
    rm -f "${tmp_bundle}" || true
    err "Bundle download failed. Verify RHSM credentials/token and BUNDLE_URL."
    return 1
  fi

  # Validate payload before replacing the target bundle file.
  if tar -tzf "${tmp_bundle}" >/dev/null 2>&1 || tar -tf "${tmp_bundle}" >/dev/null 2>&1; then
    mv -f "${tmp_bundle}" "${DOWNLOAD_DIR}/${BUNDLE_FILE}"
    if id "${controller_user}" >/dev/null 2>&1; then
      chown "${controller_user}:${controller_user}" "${DOWNLOAD_DIR}/${BUNDLE_FILE}" 2>/dev/null || true
    fi
  else
    local local_bundle_path
    file_type="$(file -b "${tmp_bundle}" 2>/dev/null || echo "unknown")"
    err "Downloaded file is not a valid tar archive."
    err "Detected file type: ${file_type}"
    warn "The URL likely returned a login/error page. Confirm Step 6 credentials and the BUNDLE_URL value."
    warn "First lines of downloaded content:"
    head -n 5 "${tmp_bundle}" 2>/dev/null | sed 's/^/  /' || true

    if [[ "${retry_depth}" -lt 1 && "${NONINTERACTIVE}" != "true" ]]; then
      read -r -p "Re-enter Red Hat CDN username/password and retry download now? [Y/n]: " retry_creds
      if [[ ! "${retry_creds:-Y}" =~ ^[Nn]$ ]]; then
        read -r -p "Enter RHSM_USERNAME (Red Hat Login/CDN/registry/console username): " RHSM_USERNAME
        read_secret_prompt RHSM_PASSWORD "Enter RHSM_PASSWORD (Red Hat Login/CDN/registry/console password)"
        save_env_kv "RHSM_USERNAME" "${RHSM_USERNAME}"
        save_env_kv "RHSM_PASSWORD" "${RHSM_PASSWORD}"
        rm -f "${tmp_bundle}" || true
        download_bundle "$((retry_depth + 1))"
        return $?
      fi
    fi

    if [[ "${NONINTERACTIVE}" == "true" ]]; then
      err "Non-interactive mode: cannot prompt for a local bundle path. Aborting download."
      rm -f "${tmp_bundle}" || true
      return 1
    fi

    read -r -p "Enter local path to a valid AAP bundle tar.gz (or press ENTER to abort): " local_bundle_path
    if [[ -n "${local_bundle_path}" && -f "${local_bundle_path}" ]]; then
      if tar -tzf "${local_bundle_path}" >/dev/null 2>&1 || tar -tf "${local_bundle_path}" >/dev/null 2>&1; then
        cp -f "${local_bundle_path}" "${DOWNLOAD_DIR}/${BUNDLE_FILE}"
        if id "${controller_user}" >/dev/null 2>&1; then
          chown "${controller_user}:${controller_user}" "${DOWNLOAD_DIR}/${BUNDLE_FILE}" 2>/dev/null || true
        fi
        rm -f "${tmp_bundle}" || true
        ok "Using local bundle file: ${local_bundle_path}"
        ok "Setup bundle download completed: ${BUNDLE_FILE}."
        return 0
      else
        err "Provided local file is not a valid tar archive: ${local_bundle_path}"
      fi
    fi

    rm -f "${tmp_bundle}" || true
    return 1
  fi

  ok "Setup bundle download completed: ${BUNDLE_FILE}."
}

extract_bundle() {
  local bundle_path file_type tar_flag actual_dir_name

  bundle_path="${DOWNLOAD_DIR}/${BUNDLE_FILE}"

  if [[ ! -f "${DOWNLOAD_DIR}/${BUNDLE_FILE}" ]]; then
    err "Setup bundle not found: ${DOWNLOAD_DIR}/${BUNDLE_FILE}"
    return 1
  fi

  log "Extracting ${BUNDLE_FILE} in ${DOWNLOAD_DIR}."

  if tar -tzf "${bundle_path}" >/dev/null 2>&1; then
    tar_flag="-xzf"
  elif tar -tf "${bundle_path}" >/dev/null 2>&1; then
    tar_flag="-xf"
  else
    file_type="$(file -b "${bundle_path}" 2>/dev/null || echo "unknown")"
    err "Downloaded file is not a valid tar archive: ${bundle_path}"
    err "Detected file type: ${file_type}"
    warn "This usually means the download URL returned an HTML/login/error page instead of the bundle."
    warn "Re-run Step 6 to refresh credentials/tokens, then Step 7 to re-download the bundle."
    warn "First lines of the file for quick diagnosis:"
    head -n 5 "${bundle_path}" 2>/dev/null | sed 's/^/  /' || true
    return 1
  fi

  # The archive's top-level folder name reflects the actual bundle version,
  # which can differ from BUNDLE_DIR_NAME if a non-default BUNDLE_URL was used.
  actual_dir_name="$(tar -tf "${bundle_path}" 2>/dev/null | head -n1 | cut -d/ -f1)"

  tar "${tar_flag}" "${bundle_path}" -C "${DOWNLOAD_DIR}"

  if [[ -n "${actual_dir_name}" && "${actual_dir_name}" != "${BUNDLE_DIR_NAME}" && -d "${DOWNLOAD_DIR}/${actual_dir_name}" ]]; then
    warn "Extracted bundle directory (${actual_dir_name}) differs from expected (${BUNDLE_DIR_NAME}); updating installer state."
    BUNDLE_DIR_NAME="${actual_dir_name}"
    INVENTORY_FILE="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"
    save_env_kv "BUNDLE_DIR_NAME" "${BUNDLE_DIR_NAME}"
  fi

  local controller_user
  controller_user="$(get_controller_user)"
  chown -R "${controller_user}:${controller_user}" "${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}" 2>/dev/null || true
  ok "Bundle extracted to ${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}."
}

ensure_all_vars_section() {
  local file="$1"
  if ! grep -q '^\[all:vars\]' "${file}"; then
    printf '\n[all:vars]\n' >> "${file}"
  fi
}

upsert_inventory_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}='${value//\'/\'\"\'\"\'}'|" "${file}"
  else
    awk -v k="${key}" -v v="${value}" '
      BEGIN { done=0 }
      { print }
      /^\[all:vars\]$/ && done==0 { print k "=\x27" v "\x27"; done=1 }
    ' "${file}" >"${file}.tmp" && mv "${file}.tmp" "${file}"
  fi
}

inventory_baseline_path() {
  local file="$1"
  printf '%s.pre_script.bak' "${file}"
}

ensure_inventory_baseline_backup() {
  local file="$1"
  local baseline

  if [[ ! -f "${file}" ]]; then
    return 0
  fi

  baseline="$(inventory_baseline_path "${file}")"
  if [[ -f "${baseline}" ]]; then
    return 0
  fi

  cp -p "${file}" "${baseline}"
  ok "Created inventory baseline backup: ${baseline}"
}

run_post_uninstall_cleanup() {
  local install_dir="$1"
  local inv_file baseline purge_reply purge_downloads

  inv_file="${install_dir}/inventory-growth"
  baseline="$(inventory_baseline_path "${inv_file}")"
  purge_downloads="false"

  load_env
  if [[ "${AAP_CLEANUP_PURGE_DOWNLOADS:-}" =~ ^([Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1)$ ]]; then
    purge_downloads="true"
  elif [[ "${NONINTERACTIVE}" != "true" && -t 0 ]]; then
    read -r -p "Also remove downloaded bundle artifacts (${install_dir} and ${DOWNLOAD_DIR}/${BUNDLE_FILE})? [y/N]: " purge_reply
    if [[ "${purge_reply:-N}" =~ ^[Yy]$ ]]; then
      purge_downloads="true"
    fi
  fi

  if [[ -f "${baseline}" ]]; then
    cp -f "${baseline}" "${inv_file}"
    ok "Restored inventory-growth from baseline backup: ${baseline}"
  else
    warn "No inventory baseline backup found at ${baseline}; inventory-growth was not restored."
  fi

  if [[ -f "${ENV_FILE}" ]]; then
    rm -f "${ENV_FILE}"
    ok "Removed installer environment file: ${ENV_FILE}"
  else
    log "INFO" "No installer environment file present at ${ENV_FILE}."
  fi

  if [[ "${purge_downloads}" == "true" ]]; then
    if [[ -d "${install_dir}" ]]; then
      rm -rf "${install_dir}"
      ok "Removed extracted bundle directory: ${install_dir}"
    fi
    if [[ -f "${DOWNLOAD_DIR}/${BUNDLE_FILE}" ]]; then
      rm -f "${DOWNLOAD_DIR}/${BUNDLE_FILE}"
      ok "Removed downloaded bundle archive: ${DOWNLOAD_DIR}/${BUNDLE_FILE}"
    fi
  else
    log "INFO" "Bundle artifacts were retained. Set AAP_CLEANUP_PURGE_DOWNLOADS=true in ${ENV_FILE} to auto-remove them."
  fi
}

should_run_post_uninstall_cleanup() {
  local reply

  load_env
  if [[ "${AAP_AUTO_CLEANUP_ON_UNINSTALL:-}" =~ ^([Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1)$ ]]; then
    return 0
  fi

  if [[ "${NONINTERACTIVE}" == "true" || ! -t 0 ]]; then
    return 1
  fi

  read -r -p "Run post-uninstall cleanup of script-managed changes (restore inventory + clear env file)? [y/N]: " reply
  [[ "${reply:-N}" =~ ^[Yy]$ ]]
}

ensure_registry_credentials() {
  load_env

  if [[ -z "${RHSM_USERNAME:-}" ]]; then
    ask_value RHSM_USERNAME "Enter RHSM_USERNAME (Red Hat Login/CDN/registry/console username)" "${DEFAULT_RHSM_USERNAME}" || return 1
    save_env_kv "RHSM_USERNAME" "${RHSM_USERNAME}"
  fi

  if [[ -z "${RHSM_PASSWORD:-}" ]]; then
    read_secret_prompt RHSM_PASSWORD "Enter RHSM_PASSWORD (Red Hat Login/CDN/registry/console password)"
    save_env_kv "RHSM_PASSWORD" "${RHSM_PASSWORD}"
  fi
}

# shellcheck source=lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"

modify_inventory_growth() {
  load_env
  ensure_registry_credentials

  local inv_file admin_password target_domain host_line escaped_admin_password
  inv_file="${INVENTORY_FILE}"
  admin_password="${ADMIN_PASSWORD:-}"
  resolve_target_context
  target_domain="$(derive_domain_from_fqdn "${TARGET_FQDN}")"
  host_line="$(build_inventory_host_line)"

  if [[ ! -f "${inv_file}" ]]; then
    err "inventory-growth not found: ${inv_file}"
    return 1
  fi

  ensure_inventory_baseline_backup "${inv_file}"

  if [[ -z "${admin_password}" ]]; then
    warn "ADMIN_PASSWORD not found in environment file; prompting now."
    read_secret_prompt admin_password "Enter platform admin password for inventory values"
    save_env_kv "ADMIN_PASSWORD" "${admin_password}"
  fi

  escaped_admin_password="$(printf '%s' "${admin_password}" | sed -e 's/[\\/&]/\\&/g')"

  sed -E -i "s@aap\.example\.(com|org)@${TARGET_FQDN}@g" "${inv_file}"
  sed -E -i "s@(^|[^[:alnum:]_])example\.(com|org)([^[:alnum:]_]|$)@\\1${target_domain}\\3@g" "${inv_file}"
  sed -i "s|password=<set your own>|password={{ admin_password }}|g" "${inv_file}"
  sed -i "s|collections=false|collections=true|g" "${inv_file}"
  sed -E -i "s@\{\{[[:space:]]*admin_password[[:space:]]*\}\}@${escaped_admin_password}@g" "${inv_file}"

  # Normalize all inventory host lines so reruns cannot keep stale aliases/domains.
  awk -v normalized_host_line="${host_line}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    /^\[all:vars\]/ { in_all_vars = 1; print; next }
    /^\[/ { in_all_vars = 0; print; next }
    in_all_vars == 0 {
      print normalized_host_line
      next
    }
    { print }
  ' "${inv_file}" > "${inv_file}.tmp" && mv "${inv_file}.tmp" "${inv_file}"

  ensure_all_vars_section "${inv_file}"

  upsert_inventory_var "${inv_file}" "admin_password" "${admin_password}"
  upsert_inventory_var "${inv_file}" "pg_admin_password" "${admin_password}"
  upsert_inventory_var "${inv_file}" "registry_username" "${RHSM_USERNAME:-}"
  upsert_inventory_var "${inv_file}" "registry_password" "${RHSM_PASSWORD:-}"
  upsert_inventory_var "${inv_file}" "ansible_user" "${TARGET_SSH_USER}"
  upsert_inventory_var "${inv_file}" "ansible_become" "true"
  upsert_inventory_var "${inv_file}" "ansible_become_method" "sudo"
  upsert_inventory_var "${inv_file}" "ansible_user_dir" "/home/${TARGET_SSH_USER}"
  upsert_inventory_var "${inv_file}" "ansible_connection" "ssh"
  upsert_inventory_var "${inv_file}" "redis_mode" "standalone"

  ok "inventory-growth updated successfully: ${inv_file}"
}

enforce_inventory_runtime_settings() {
  local inv_file="$1"
  local target_domain host_line controller_user controller_home known_hosts_file escaped_admin_password
  ensure_registry_credentials
  load_env
  ensure_inventory_baseline_backup "${inv_file}"
  resolve_target_context
  controller_user="$(get_controller_user)"
  controller_home="$(get_user_home "${controller_user}")"
  known_hosts_file="${controller_home}/.ssh/known_hosts"
  target_domain="$(derive_domain_from_fqdn "${TARGET_FQDN}")"
  host_line="$(build_inventory_host_line)"

  if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    read_secret_prompt ADMIN_PASSWORD "Enter platform admin password for runtime inventory values"
    save_env_kv "ADMIN_PASSWORD" "${ADMIN_PASSWORD}"
  fi
  escaped_admin_password="$(printf '%s' "${ADMIN_PASSWORD}" | sed -e 's/[\\/&]/\\&/g')"

  sed -E -i "s@aap\.example\.(com|org)@${TARGET_FQDN}@g" "${inv_file}"
  sed -E -i "s@(^|[^[:alnum:]_])example\.(com|org)([^[:alnum:]_]|$)@\\1${target_domain}\\3@g" "${inv_file}"
  sed -E -i "s@\{\{[[:space:]]*admin_password[[:space:]]*\}\}@${escaped_admin_password}@g" "${inv_file}"

  awk -v normalized_host_line="${host_line}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    /^\[all:vars\]/ { in_all_vars = 1; print; next }
    /^\[/ { in_all_vars = 0; print; next }
    in_all_vars == 0 { print normalized_host_line; next }
    { print }
  ' "${inv_file}" > "${inv_file}.tmp" && mv "${inv_file}.tmp" "${inv_file}"

  if [[ ${EUID} -eq 0 ]] && command -v runuser >/dev/null 2>&1 && id "${controller_user}" >/dev/null 2>&1; then
    runuser -u "${controller_user}" -- ssh-keygen -R aap >/dev/null 2>&1 || true
    runuser -u "${controller_user}" -- ssh-keygen -R "${TARGET_FQDN}" >/dev/null 2>&1 || true
  elif command -v sudo >/dev/null 2>&1 && id "${controller_user}" >/dev/null 2>&1; then
    HOME="${controller_home}" sudo -u "${controller_user}" ssh-keygen -R aap >/dev/null 2>&1 || true
    HOME="${controller_home}" sudo -u "${controller_user}" ssh-keygen -R "${TARGET_FQDN}" >/dev/null 2>&1 || true
  else
    ssh-keygen -f "${known_hosts_file}" -R aap >/dev/null 2>&1 || true
    ssh-keygen -f "${known_hosts_file}" -R "${TARGET_FQDN}" >/dev/null 2>&1 || true
  fi

  upsert_inventory_var "${inv_file}" "ansible_user" "${TARGET_SSH_USER}"
  upsert_inventory_var "${inv_file}" "ansible_become" "true"
  upsert_inventory_var "${inv_file}" "ansible_become_method" "sudo"
  upsert_inventory_var "${inv_file}" "ansible_user_dir" "/home/${TARGET_SSH_USER}"
  upsert_inventory_var "${inv_file}" "ansible_connection" "ssh"
  upsert_inventory_var "${inv_file}" "ansible_ssh_common_args" "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  upsert_inventory_var "${inv_file}" "registry_username" "${RHSM_USERNAME:-}"
  upsert_inventory_var "${inv_file}" "registry_password" "${RHSM_PASSWORD:-}"
  upsert_inventory_var "${inv_file}" "redis_mode" "standalone"
}

get_inventory_var() {
  local inv_file="$1"
  local key="$2"
  local raw

  raw="$(grep -E "^${key}=" "${inv_file}" | tail -n1 | cut -d= -f2- || true)"
  raw="${raw%\'}"
  raw="${raw#\'}"
  printf '%s' "${raw}"
}

run_execution_playbook() {
  local playbook_name="$1"
  local install_dir
  local runtime_host_line runtime_user runtime_become runtime_conn runtime_redis_mode remote_user remote_uid controller_user controller_home controller_key
  local ansible_verbosity
  local playbook_rc
  local -a ansible_cmd
  install_dir="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}"
  load_env
  ansible_verbosity="$(normalize_ansible_verbosity "${ANSIBLE_VERBOSITY:-}")"
  resolve_target_context
  remote_user="${TARGET_SSH_USER}"
  remote_uid="$(id -u "${remote_user}" 2>/dev/null || echo 1000)"
  controller_user="$(get_controller_user)"
  controller_home="$(get_user_home "${controller_user}")"
  controller_key="${TARGET_SSH_KEY}"

  log "INFO" "Step 10 selection: playbook=${playbook_name}, remote_user=${remote_user}, controller_user=${controller_user}"

  if [[ ! -d "${install_dir}" ]]; then
    err "Installation directory missing: ${install_dir}"
    return 1
  fi

  if [[ ! -f "${install_dir}/inventory-growth" ]]; then
    err "inventory-growth missing in ${install_dir}"
    return 1
  fi

  patch_containerized_installer_user_bus_task "${install_dir}"
  enforce_inventory_runtime_settings "${install_dir}/inventory-growth"
  run_rootless_podman_playbook "${remote_user}" true "${RHSM_USERNAME:-}" "${RHSM_PASSWORD:-}"

  runtime_host_line="$(awk '/^[[:space:]]*#/ || /^\[/ || /^[[:space:]]*$/ { next } { print; exit }' "${install_dir}/inventory-growth")"
  runtime_user="$(get_inventory_var "${install_dir}/inventory-growth" "ansible_user")"
  runtime_become="$(get_inventory_var "${install_dir}/inventory-growth" "ansible_become")"
  runtime_conn="$(get_inventory_var "${install_dir}/inventory-growth" "ansible_connection")"
  runtime_redis_mode="$(get_inventory_var "${install_dir}/inventory-growth" "redis_mode")"

  log "INFO" "Runtime inventory host line: ${runtime_host_line:-<not-found>}"
  log "INFO" "Runtime inventory vars: ansible_connection=${runtime_conn:-unset}, ansible_user=${runtime_user:-unset}, ansible_become=${runtime_become:-unset}"
  log "INFO" "Runtime inventory redis_mode=${runtime_redis_mode:-unset}"
  log "INFO" "Runtime ansible verbosity=${ansible_verbosity:-none}"

  # Pause for operator confirmation of collected variables before running installer
  echo
  echo "Collected runtime settings:" 
  echo "  Host line: ${runtime_host_line:-<not-found>}"
  echo "  Connection: ${runtime_conn:-unset}"
  echo "  Remote user: ${runtime_user:-unset}"
  echo "  Become: ${runtime_become:-unset}"
  echo "  Redis mode: ${runtime_redis_mode:-unset}"
  echo
  if ! ask_yn "Proceed with these settings and run the installer? [Y/n]:" "y"; then
    warn "Installer run cancelled by operator. Returning to menu."
    return 0
  fi

  if id "${controller_user}" >/dev/null 2>&1; then
    chown -R "${controller_user}:${controller_user}" "${install_dir}" 2>/dev/null || true
  fi
  touch "${install_dir}/aap_install.log" 2>/dev/null || true

  log "Starting playbook execution: ansible.containerized_installer.${playbook_name}"
  (
    cd "${install_dir}"
    ansible_cmd=(
      ansible-playbook
    )

    if [[ -n "${ansible_verbosity}" ]]; then
      ansible_cmd+=("${ansible_verbosity}")
    fi

    ansible_cmd+=(
      -i
      inventory-growth
      -u
      "${remote_user}"
      -c
      ssh
      -e
      "ansible_user=${remote_user}"
      -e
      "ansible_user_uid=${remote_uid}"
      -e
      ansible_connection=ssh
      -e
      "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
      -e
      redis_mode=standalone
      -e
      "registry_username=${RHSM_USERNAME:-}"
      -e
      "registry_password=${RHSM_PASSWORD:-}"
      "ansible.containerized_installer.${playbook_name}"
    )

    if [[ -f "${controller_key}" ]]; then
      ansible_cmd+=(--private-key "${controller_key}")
      ansible_cmd+=(-e "ansible_ssh_private_key_file=${controller_key}")
    else
      warn "Controller SSH key not found: ${controller_key}. SSH may fail unless agent/password auth is configured."
    fi

    if [[ "${USER:-}" == "${controller_user}" ]]; then
      env ANSIBLE_DEPRECATION_WARNINGS=False "${ansible_cmd[@]}"
    elif [[ ${EUID} -eq 0 ]] && command -v runuser >/dev/null 2>&1 && id "${controller_user}" >/dev/null 2>&1; then
      runuser -u "${controller_user}" -- env ANSIBLE_DEPRECATION_WARNINGS=False "${ansible_cmd[@]}"
    elif command -v sudo >/dev/null 2>&1 && id "${controller_user}" >/dev/null 2>&1; then
      HOME="${controller_home}" sudo -u "${controller_user}" env ANSIBLE_DEPRECATION_WARNINGS=False "${ansible_cmd[@]}"
    else
      warn "Neither runuser nor sudo was found; running ansible-playbook as current user."
      env ANSIBLE_DEPRECATION_WARNINGS=False "${ansible_cmd[@]}"
    fi
  )
  playbook_rc=$?

  if [[ "${playbook_name}" == "uninstall" && "${playbook_rc}" -eq 0 ]]; then
    if should_run_post_uninstall_cleanup; then
      run_post_uninstall_cleanup "${install_dir}"
    else
      log "INFO" "Post-uninstall cleanup skipped. Set AAP_AUTO_CLEANUP_ON_UNINSTALL=true in ${ENV_FILE} to auto-run it."
    fi
  fi

  return "${playbook_rc}"
}

run_install() {
  local choice playbook_name

  if [[ "${NONINTERACTIVE}" == "true" ]]; then
    playbook_name="${AAP_EXECUTION_PLAYBOOK:-install}"
    log "Non-interactive: running execution playbook '${playbook_name}' (set AAP_EXECUTION_PLAYBOOK to override)."
    run_execution_playbook "${playbook_name}"
    return $?
  fi

  while true; do
    clear
    cat <<'EOF'
Step 10 - Execution Playbooks
=============================
1) install
2) backup
3) bundle
4) install_standalone_mcp
5) log_gathering
6) restore
7) uninstall
8) Set Ansible verbosity (-v/-vv/-vvv)
0) Return to main menu
EOF

    read -r -p "Select execution playbook: " choice
    case "${choice}" in
      1) playbook_name="install" ;;
      2) playbook_name="backup" ;;
      3) playbook_name="bundle" ;;
      4) playbook_name="install_standalone_mcp" ;;
      5) playbook_name="log_gathering" ;;
      6) playbook_name="restore" ;;
      7) playbook_name="uninstall" ;;
      8) configure_ansible_verbosity; pause_enter; continue ;;
      0) return 0 ;;
      *) warn "Invalid execution playbook option."; pause_enter; continue ;;
    esac

    run_execution_playbook "${playbook_name}"
    return $?
  done
}

show_status() {
  load_env
  clear

  echo "AAP 2.7-2 Installation Status"
  echo "============================="
  [[ -f "${ENV_FILE}" ]] && echo "environment file .... PRESENT (${ENV_FILE})" || echo "environment file .... MISSING"
  [[ -f "${DOWNLOAD_DIR}/${BUNDLE_FILE}" ]] && echo "bundle archive ...... PRESENT" || echo "bundle archive ...... MISSING"
  [[ -d "${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}" ]] && echo "extracted bundle .... PRESENT" || echo "extracted bundle .... MISSING"
  [[ -f "${INVENTORY_FILE}" ]] && echo "inventory-growth .... PRESENT" || echo "inventory-growth .... MISSING"
  id "${ADMIN_USER}" >/dev/null 2>&1 && echo "${ADMIN_USER} user .......... PRESENT" || echo "${ADMIN_USER} user .......... MISSING"
  echo "hostname -f ......... $(hostname -f 2>/dev/null || echo unknown)"
  echo "hostname -d ......... $(hostname -d 2>/dev/null || echo unknown)"
  echo
  pause_enter
}

run_quick_standard_install_flow() {
  log "Quick flow: Step 1 install scope"
  initial_install_scope_prompt

  log "Quick flow: Step 2 preflight checks"
  preflight_dependency_checks

  log "Quick flow: Step 3 prework packages"
  prework_packages

  if ask_yn "Quick flow: apply installation firewall/SELinux relaxations (lab mode)? [y/N]:" "n"; then
    log "Quick flow: Step 4 firewall/SELinux relaxations"
    disable_firewall_selinux
  else
    log "Quick flow: skipping firewall/SELinux relaxations (production-safe default)."
  fi

  log "Quick flow: Step 5 host identity"
  set_fqdn_and_hosts

  log "Quick flow: Step 6 admin user"
  setup_admin_user || { err "Admin user setup failed; returning to main menu."; return 1; }

  log "Quick flow: Step 7 credentials and tokens"
  capture_credentials || { err "Credential capture failed; returning to main menu."; return 1; }

  log "Quick flow: Step 8 bundle download"
  download_bundle || { err "Bundle download failed; returning to main menu."; return 1; }

  log "Quick flow: Step 9 bundle extraction"
  extract_bundle || { err "Bundle extraction failed; returning to main menu."; return 1; }

  log "Quick flow: Step 10 inventory update"
  modify_inventory_growth || { err "Inventory update failed; returning to main menu."; return 1; }

  log "Quick flow complete. Launching execution playbook submenu."
  run_install
}

inspect_menu() {
  local choice

  while true; do
    clear
    cat <<'EOF'
Inspect
=======
1) View installation checklist
2) View installation status
3) View checklist, then status
0) Back
EOF

    read -r -p "Select inspect option: " choice
    case "${choice}" in
      1) show_checklist ;;
      2) show_status ;;
      3) show_checklist; show_status ;;
      0) return 0 ;;
      *) warn "Invalid inspect option."; pause_enter ;;
    esac
  done
}

advanced_menu() {
  local choice

  while true; do
    clear
    cat <<'EOF'
Advanced Step-by-Step Menu
==========================
1) Run preflight dependency checks
2) View installation checklist
3) Install required prework packages
4) Apply installation firewall/SELinux settings
5) Configure host identity (FQDN/domain + /etc/hosts)
6) Provision admin user (NOPASSWD sudo + SSH keys)
7) Capture RHSM credentials and tokens
8) Download setup bundle
9) Extract setup bundle
10) Update inventory-growth
11) Execute playbook (submenu)
12) View installation status
0) Back to main menu

Enter step? for contextual guidance (example: 6?)
EOF

    read -r -p "Select advanced option: " choice
    case "${choice}" in
      1) preflight_dependency_checks || true; pause_enter ;;
      2) show_checklist ;;
      3) prework_packages || true; pause_enter ;;
      3\?) show_step_help 2 ;;
      4) disable_firewall_selinux || true; pause_enter ;;
      4\?) show_step_help 3 ;;
      5) set_fqdn_and_hosts || true; pause_enter ;;
      5\?) show_step_help 4 ;;
      6) setup_admin_user || true; pause_enter ;;
      6\?) show_step_help 5 ;;
      7) capture_credentials || true; pause_enter ;;
      7\?) show_step_help 6 ;;
      8) download_bundle || true; pause_enter ;;
      8\?) show_step_help 7 ;;
      9) extract_bundle || true; pause_enter ;;
      9\?) show_step_help 8 ;;
      10) modify_inventory_growth || true; pause_enter ;;
      10\?) show_step_help 9 ;;
      11) run_install || true; pause_enter ;;
      11\?) show_step_help 10 ;;
      12) show_status ;;
      0) return 0 ;;
      *) warn "Invalid advanced option."; pause_enter ;;
    esac
  done
}

menu() {
  local choice

  while true; do
    clear
    cat <<'EOF'
AAP 2.7-2 Production Installer Assistant
========================================
1) Quick standard install flow
2) Run preflight dependency checks
3) Prepare host (packages, identity, admin user, credentials)
4) Prepare bundle (download, extract, update inventory)
5) Execute playbook (submenu)
6) Inspect (checklist/status)
7) Advanced step-by-step menu
8) Set install scope (local/remote)
0) Exit
EOF

    read -r -p "Select menu option: " choice
    case "${choice}" in
      1) run_quick_standard_install_flow || true; pause_enter ;;
      2) preflight_dependency_checks || true; pause_enter ;;
      3)
        initial_install_scope_prompt
        prework_packages || true
        set_fqdn_and_hosts || true
        setup_admin_user || true
        capture_credentials || true
        pause_enter
        ;;
      4)
        download_bundle || true
        extract_bundle || true
        modify_inventory_growth || true
        pause_enter
        ;;
      5) run_install || true; pause_enter ;;
      6) inspect_menu ;;
      7) advanced_menu ;;
      8) initial_install_scope_prompt; pause_enter ;;
      0) exit 0 ;;
      *) warn "Invalid menu option."; pause_enter ;;
    esac
  done
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --non-interactive|-y) NONINTERACTIVE=true ;;
    esac
  done
  if [[ "${NONINTERACTIVE}" != "true" && ! -t 0 ]]; then
    NONINTERACTIVE=true
    warn "stdin is not a terminal; forcing non-interactive mode."
  fi

  validate_admin_identity
  require_root
  enforce_admin_home_ownership
  mkdir -p "${DOWNLOAD_DIR}"
  initialize_env_file
  # Prompt whether this is a local or remote install and prepare inventory
  initial_install_scope_prompt

  if [[ "${NONINTERACTIVE}" == "true" ]]; then
    log "Non-interactive mode: running the quick standard install flow automatically."
    run_quick_standard_install_flow
    exit $?
  fi

  menu
}

initial_install_scope_prompt() {
  local choice ctl_ip ctl_fqdn ctl_shorthost ctl_domain saved_fqdn default_shorthost default_domain
  local install_host inv_dir inv_file local_controller_key

  inv_dir="${SCRIPT_DIR}/aap_workflow_project/inventory"
  inv_file="${inv_dir}/controller.ini"

  mkdir -p "${inv_dir}"
  load_env

  while true; do
    if [[ "${NONINTERACTIVE}" == "true" ]]; then
      case "${INSTALL_SCOPE:-}" in
        remote) choice="2" ;;
        *) choice="1" ;;
      esac
      log "Non-interactive: using install scope option ${choice} (INSTALL_SCOPE=${INSTALL_SCOPE:-local})."
    else
      clear
      cat <<'EOF'
Installation Mode
=================
1) Local (install on this system)
2) Remote (install on remote controller)
EOF

      read -r -p "Select option (1/2): " choice
    fi
    case "${choice}" in
      1)
        log "Selected local install. Inventory set to use localhost."
        cat > "${inv_file}" <<EOF
[controller]
localhost ansible_connection=local

[installhost]
$(hostname -f 2>/dev/null || hostname) ansible_connection=local

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF
        save_env_kv "INSTALL_SCOPE" "local"
        break
        ;;
      2)
        ctl_ip="${AAP_CONTROLLER_IP:-}"
        ask_value ctl_ip "Enter controller IP or hostname (example: 192.0.2.10)" "${AAP_CONTROLLER_IP:-}" || return 1
        saved_fqdn="${AAP_CONTROLLER_FQDN:-}"
        default_shorthost="aap"
        default_domain="example.com"
        if [[ -n "${saved_fqdn}" ]]; then
          default_shorthost="${saved_fqdn%%.*}"
          if [[ "${saved_fqdn}" == *.* ]]; then
            default_domain="${saved_fqdn#*.}"
          fi
        fi
        ctl_shorthost=""
        ask_value ctl_shorthost "What will the system short hostname be [${default_shorthost}]" "${default_shorthost}"
        ctl_domain=""
        ask_value ctl_domain "What is the domain for your machine [${default_domain}]" "${default_domain}"
        ctl_fqdn="${ctl_shorthost}.${ctl_domain}"
        if [[ -z "${ctl_ip}" && -z "${ctl_fqdn}" ]]; then
          warn "Controller host is required for remote installs."
          if [[ "${NONINTERACTIVE}" == "true" ]]; then
            err "Non-interactive mode: no controller IP available. Set AAP_CONTROLLER_IP in ${ENV_FILE} and re-run."
            return 1
          fi
          continue
        fi
        ctl_ip="${ctl_ip:-${ctl_fqdn}}"
        install_host="$(hostname -f 2>/dev/null || hostname)"
        # Private key lives on THIS (local/controller) host under the invoking
        # user's home; admin's account/home is provisioned on the remote target.
        local_controller_key="${CONTROLLER_STATE_HOME}/.ssh/id_ed25519"

        log "Writing remote inventory to ${inv_file} (controller=${ctl_fqdn}, ansible_host=${ctl_ip})"
        cat > "${inv_file}" <<EOF
[controller]
${ctl_fqdn} ansible_host=${ctl_ip} ansible_user=${ADMIN_USER} ansible_ssh_private_key_file=${local_controller_key}

[installhost]
${install_host} ansible_connection=local

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF

        save_env_kv "INSTALL_SCOPE" "remote"
        save_env_kv "AAP_CONTROLLER_IP" "${ctl_ip}"
        save_env_kv "AAP_CONTROLLER_FQDN" "${ctl_fqdn}"
        break
        ;;
      *)
        warn "Invalid option. Please select 1 or 2."
        ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
set -euo pipefail

BUNDLE_FILE="ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64.tar.gz"
BUNDLE_URL_DEFAULT="https://access.cdn.redhat.com/content/origin/files/sha256/5c/5c0e1834c1ae609ce840865b5aa279b5c5bde9118856b326f77cc5c8bf92d9af/ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64.tar.gz"
BUNDLE_DIR_NAME="ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64"
ADMIN_HOME="/home/admin"
DOWNLOAD_DIR="${ADMIN_HOME}/Downloads"
ENV_FILE="${ADMIN_HOME}/.aap27_install.env"
INVENTORY_FILE="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}/inventory-growth"

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

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "Run as root or with sudo."
    exit 1
  fi
}

pause_enter() {
  read -r -p "Press ENTER to continue..." _unused
}

load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
  fi
}

save_env_kv() {
  local key="$1"
  local val="$2"

  mkdir -p "$(dirname "${ENV_FILE}")"
  touch "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"

  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}='${val//\'/\'\"\'\"\'}'|" "${ENV_FILE}"
  else
    echo "${key}='${val//\'/\'\"\'\"\'}'" >> "${ENV_FILE}"
  fi
}

ensure_admin_user_exists() {
  if id admin >/dev/null 2>&1; then
    return 0
  fi

  warn "admin user does not exist; creating it now."
  if [[ -d "${ADMIN_HOME}" ]]; then
    useradd -M -d "${ADMIN_HOME}" -s /bin/bash admin
  else
    useradd -m -s /bin/bash admin
  fi

  if [[ -d "${ADMIN_HOME}" ]]; then
    chown admin:admin "${ADMIN_HOME}"
    chmod 0750 "${ADMIN_HOME}" || true
  fi

  ok "admin user created."
}

show_checklist() {
  clear
  cat <<'EOF'
AAP 2.7-2 INSTALLATION CHECKLIST
================================
Execute steps in the order shown:
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
EOF
  pause_enter
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
- Configures passwordless sudo in /etc/sudoers.d/admin.
- Generates /home/admin/.ssh/id_ed25519.
- Attempts ssh-copy-id to admin@<hostname>.
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

Captured values are stored in /home/admin/.aap27_install.env (mode 0600).
EOF
      ;;
    7)
      cat <<'EOF'
Step 7 - Download Bundle
------------------------
- Downloads bundle to /home/admin/Downloads/
- Uses file name:
  ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64.tar.gz
EOF
      ;;
    8)
      cat <<'EOF'
Step 8 - Extract Bundle
-----------------------
- Extracts tarball under /home/admin/Downloads.
- Expected extraction directory:
  /home/admin/Downloads/ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64
EOF
      ;;
    9)
      cat <<'EOF'
Step 9 - Modify inventory-growth
--------------------------------
- Updates:
  aap.example.com -> aap ansible_host={{ ansible_ip_address }} real_hostname={{ hostname }} ansible_user=admin ansible_ssh_private_key_file=/home/admin/.ssh/id_ed25519
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
/home/admin/Downloads/ansible-automation-platform-containerized-setup-bundle-2.7-2-x86_64
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
  read -r -s -p "${prompt}: " value
  echo
  printf -v "${var_name}" '%s' "${value}"
}

prework_packages() {
  local yn
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
    python3
    python3-pip
    ansible-core
  )

  log "Proposed prework packages:"
  printf ' - %s\n' "${packages[@]}"
  read -r -p "Proceed with package installation? [Y/n]: " yn
  if [[ "${yn:-Y}" =~ ^[Nn]$ ]]; then
    warn "Prework package installation skipped by operator."
    return 0
  fi

  log "Installing required prework packages."

  if command -v dnf >/dev/null 2>&1; then
    dnf -y install "${packages[@]}" || warn "One or more packages failed to install."
  else
    warn "dnf not found; package installation skipped."
  fi

  systemctl enable --now sshd || warn "Unable to enable/start sshd."
  ok "Prework package installation step completed."
}

disable_firewall_selinux() {
  local yn

  cat <<'EOF'
Planned system changes:
- Disable and stop firewalld service
- Set SELinux runtime mode to permissive (setenforce 0)
- Set SELINUX=permissive in /etc/selinux/config
EOF
  read -r -p "Apply these installation-mode security changes? [y/N]: " yn
  if [[ ! "${yn:-N}" =~ ^[Yy]$ ]]; then
    warn "Firewall/SELinux changes skipped by operator."
    return 0
  fi

  log "Applying installation-mode firewall and SELinux settings."

  if systemctl is-active --quiet firewalld; then
    systemctl disable --now firewalld
  else
    warn "firewalld is already stopped or not installed."
  fi

  if command -v setenforce >/dev/null 2>&1; then
    setenforce 0 || warn "Unable to set SELinux runtime mode to permissive."
  fi

  if [[ -f /etc/selinux/config ]]; then
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
  fi

  ok "Firewall and SELinux settings applied."
}

set_fqdn_and_hosts() {
  local current_fqdn current_domain target_fqdn target_domain system_ip yn

  current_fqdn="$(hostname -f 2>/dev/null || true)"
  current_domain="$(hostname -d 2>/dev/null || true)"

  log "Detected FQDN: ${current_fqdn:-<not-set>}"
  log "Detected domain: ${current_domain:-<not-set>}"

  if [[ -z "${current_fqdn}" || "${current_fqdn}" == "localhost" || "${current_fqdn}" == "localhost.localdomain" ]]; then
    read -r -p "Enter target system FQDN (example: aap.example.com): " target_fqdn
    if [[ -z "${target_fqdn}" ]]; then
      err "FQDN is required."
      return 1
    fi
  else
    read -r -p "Use detected FQDN '${current_fqdn}'? [Y/n]: " yn
    if [[ "${yn:-Y}" =~ ^[Nn]$ ]]; then
      read -r -p "Enter target system FQDN: " target_fqdn
      if [[ -z "${target_fqdn}" ]]; then
        err "FQDN is required."
        return 1
      fi
    else
      target_fqdn="${current_fqdn}"
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

  cat <<EOF
Planned host identity changes:
- hostnamectl set-hostname ${target_fqdn}
- /etc/hosts entry ensured: ${system_ip} ${target_fqdn} aap
- domain value to apply: ${target_domain:-<none>}
EOF
  read -r -p "Apply these host identity changes? [y/N]: " yn
  if [[ ! "${yn:-N}" =~ ^[Yy]$ ]]; then
    warn "Host identity changes skipped by operator."
    return 0
  fi

  hostnamectl set-hostname "${target_fqdn}"

  if [[ -n "${target_domain}" ]]; then
    if command -v domainname >/dev/null 2>&1; then
      domainname "${target_domain}" || warn "Unable to set domainname value."
    fi
    if [[ -f /etc/sysconfig/network ]]; then
      if grep -q '^DOMAINNAME=' /etc/sysconfig/network; then
        sed -i "s/^DOMAINNAME=.*/DOMAINNAME=${target_domain}/" /etc/sysconfig/network
      else
        echo "DOMAINNAME=${target_domain}" >> /etc/sysconfig/network
      fi
    fi
  else
    warn "No domain component detected in FQDN; domain-specific updates skipped."
  fi

  sed -i "/[[:space:]]${target_fqdn//./\\.}[[:space:]]/d" /etc/hosts || true
  sed -i "/[[:space:]]aap$/d" /etc/hosts || true
  echo "${system_ip} ${target_fqdn} aap" >> /etc/hosts

  ok "Host identity updated. FQDN=${target_fqdn}, domain=${target_domain:-<unset>}."
}

setup_admin_user() {
  local host_fqdn admin_password

  ensure_admin_user_exists
  log "admin user is present."

  cat >/etc/sudoers.d/admin <<'EOF'
admin ALL=(ALL) NOPASSWD: ALL
EOF
  chmod 0440 /etc/sudoers.d/admin

  # Ensure admin home and SSH directory are writable by admin before key operations.
  if [[ -d "${ADMIN_HOME}" ]]; then
    chown admin:admin "${ADMIN_HOME}"
    chmod 0750 "${ADMIN_HOME}" || true
  fi

  mkdir -p "${ADMIN_HOME}/.ssh"
  chown admin:admin "${ADMIN_HOME}/.ssh"
  chmod 700 "${ADMIN_HOME}/.ssh"

  if [[ ! -f "${ADMIN_HOME}/.ssh/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -N "" -f "${ADMIN_HOME}/.ssh/id_ed25519" >/dev/null
    chown admin:admin "${ADMIN_HOME}/.ssh/id_ed25519" "${ADMIN_HOME}/.ssh/id_ed25519.pub"
    chmod 600 "${ADMIN_HOME}/.ssh/id_ed25519"
    chmod 644 "${ADMIN_HOME}/.ssh/id_ed25519.pub"
  fi

  read_secret_prompt admin_password "Enter password for admin user"
  echo "admin:${admin_password}" | chpasswd
  save_env_kv "ADMIN_PASSWORD" "${admin_password}"

  host_fqdn="$(hostname -f 2>/dev/null || hostname)"

  if command -v sshpass >/dev/null 2>&1; then
    log "Copying admin SSH key to admin@${host_fqdn}."
    sshpass -p "${admin_password}" ssh-copy-id \
      -o StrictHostKeyChecking=no \
      -i "${ADMIN_HOME}/.ssh/id_ed25519.pub" \
      "admin@${host_fqdn}" || warn "ssh-copy-id failed; continuing."
  else
    warn "sshpass is not installed; skipping ssh-copy-id."
  fi

  chown -R admin:admin "${ADMIN_HOME}/.ssh"
  ok "admin user setup complete."
}

capture_credentials() {
  local rhsm_user rhsm_pass offline_token hub_token bundle_url

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

  read -r -p "Enter RHSM_USERNAME (Red Hat Login/CDN/registry/console username): " rhsm_user
  read_secret_prompt rhsm_pass "Enter RHSM_PASSWORD (Red Hat Login/CDN/registry/console password)"
  read_secret_prompt offline_token "Enter RH_OFFLINE_TOKEN (from access.redhat.com)"
  read_secret_prompt hub_token "Enter RH_AH_TOKEN (Remote Automation Hub token)"
  read -r -p "Bundle URL [ENTER for default]: " bundle_url

  save_env_kv "RHSM_USERNAME" "${rhsm_user}"
  save_env_kv "RHSM_PASSWORD" "${rhsm_pass}"
  save_env_kv "RH_OFFLINE_TOKEN" "${offline_token}"
  save_env_kv "RH_AH_TOKEN" "${hub_token}"
  save_env_kv "BUNDLE_URL" "${bundle_url:-$BUNDLE_URL_DEFAULT}"

  ok "Credentials and tokens saved to ${ENV_FILE} (mode 600)."
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

    if [[ "${retry_depth}" -lt 1 ]]; then
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
  local bundle_path file_type
  bundle_path="${DOWNLOAD_DIR}/${BUNDLE_FILE}"

  if [[ ! -f "${DOWNLOAD_DIR}/${BUNDLE_FILE}" ]]; then
    err "Setup bundle not found: ${DOWNLOAD_DIR}/${BUNDLE_FILE}"
    return 1
  fi

  log "Extracting ${BUNDLE_FILE} in ${DOWNLOAD_DIR}."

  if tar -tzf "${bundle_path}" >/dev/null 2>&1; then
    tar -xzf "${bundle_path}" -C "${DOWNLOAD_DIR}"
  elif tar -tf "${bundle_path}" >/dev/null 2>&1; then
    tar -xf "${bundle_path}" -C "${DOWNLOAD_DIR}"
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

  chown -R admin:admin "${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}" || true
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

ensure_registry_credentials() {
  load_env

  if [[ -z "${RHSM_USERNAME:-}" ]]; then
    read -r -p "Enter RHSM_USERNAME (Red Hat Login/CDN/registry/console username): " RHSM_USERNAME
    save_env_kv "RHSM_USERNAME" "${RHSM_USERNAME}"
  fi

  if [[ -z "${RHSM_PASSWORD:-}" ]]; then
    read_secret_prompt RHSM_PASSWORD "Enter RHSM_PASSWORD (Red Hat Login/CDN/registry/console password)"
    save_env_kv "RHSM_PASSWORD" "${RHSM_PASSWORD}"
  fi
}

get_preferred_remote_user() {
  local selected_user use_admin

  load_env

  if [[ -n "${AAP_REMOTE_USER:-}" ]]; then
    printf '%s' "${AAP_REMOTE_USER}"
    return
  fi

  if id admin >/dev/null 2>&1; then
    selected_user="admin"
  else
    warn "admin user does not exist on this host."
    read -r -p "Use admin as the AAP SSH user? [Y/n]: " use_admin
    if [[ ! "${use_admin:-Y}" =~ ^[Nn]$ ]]; then
      selected_user="admin"
    else
      read -r -p "Enter AAP SSH user [admin]: " selected_user
      selected_user="${selected_user:-admin}"
    fi

    if ! id "${selected_user}" >/dev/null 2>&1; then
      warn "Selected user '${selected_user}' does not currently exist. Create it or run Step 5 if you intend to use admin."
    fi
  fi

  AAP_REMOTE_USER="${selected_user}"
  save_env_kv "AAP_REMOTE_USER" "${AAP_REMOTE_USER}"
  printf '%s' "${AAP_REMOTE_USER}"
}

get_user_home() {
  local user_name="$1"
  local user_home
  user_home="$(getent passwd "${user_name}" | cut -d: -f6 || true)"
  if [[ -z "${user_home}" ]]; then
    user_home="/home/${user_name}"
  fi
  printf '%s' "${user_home}"
}

get_controller_user() {
  local selected_user

  load_env
  if [[ -n "${AAP_CONTROLLER_USER:-}" ]]; then
    printf '%s' "${AAP_CONTROLLER_USER}"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id "${SUDO_USER}" >/dev/null 2>&1; then
    selected_user="${SUDO_USER}"
  elif [[ -n "${USER:-}" && "${USER}" != "root" ]] && id "${USER}" >/dev/null 2>&1; then
    selected_user="${USER}"
  elif id admin >/dev/null 2>&1; then
    selected_user="admin"
  else
    selected_user="root"
  fi

  AAP_CONTROLLER_USER="${selected_user}"
  save_env_kv "AAP_CONTROLLER_USER" "${AAP_CONTROLLER_USER}"
  printf '%s' "${AAP_CONTROLLER_USER}"
}

get_controller_ssh_key() {
  local controller_user controller_home key_path

  load_env
  if [[ -n "${AAP_CONTROLLER_SSH_KEY:-}" ]]; then
    printf '%s' "${AAP_CONTROLLER_SSH_KEY}"
    return
  fi

  controller_user="$(get_controller_user)"
  controller_home="$(get_user_home "${controller_user}")"
  key_path="${controller_home}/.ssh/id_ed25519"

  AAP_CONTROLLER_SSH_KEY="${key_path}"
  save_env_kv "AAP_CONTROLLER_SSH_KEY" "${AAP_CONTROLLER_SSH_KEY}"
  printf '%s' "${AAP_CONTROLLER_SSH_KEY}"
}

modify_inventory_growth() {
  load_env
  ensure_registry_credentials

  local inv_file admin_password target_fqdn target_domain host_line remote_user controller_key escaped_admin_password
  inv_file="${INVENTORY_FILE}"
  admin_password="${ADMIN_PASSWORD:-}"
  remote_user="$(get_preferred_remote_user)"
  controller_key="$(get_controller_ssh_key)"
  target_fqdn="$(hostname -f 2>/dev/null || echo aap.localdomain)"
  target_domain="${target_fqdn#*.}"
  if [[ "${target_domain}" == "${target_fqdn}" || -z "${target_domain}" ]]; then
    target_domain="localdomain"
  fi
  host_line="${target_fqdn} ansible_host=${target_fqdn} real_hostname=${target_fqdn} ansible_user=${remote_user} ansible_ssh_private_key_file=${controller_key}"

  if [[ ! -f "${inv_file}" ]]; then
    err "inventory-growth not found: ${inv_file}"
    return 1
  fi

  if [[ -z "${admin_password}" ]]; then
    warn "ADMIN_PASSWORD not found in environment file; prompting now."
    read_secret_prompt admin_password "Enter platform admin password for inventory values"
    save_env_kv "ADMIN_PASSWORD" "${admin_password}"
  fi

  escaped_admin_password="$(printf '%s' "${admin_password}" | sed -e 's/[\\/&]/\\&/g')"

  sed -E -i "s@aap\.example\.(com|org)@${target_fqdn}@g" "${inv_file}"
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
  upsert_inventory_var "${inv_file}" "ansible_user" "${remote_user}"
  upsert_inventory_var "${inv_file}" "ansible_become" "true"
  upsert_inventory_var "${inv_file}" "ansible_connection" "ssh"
  upsert_inventory_var "${inv_file}" "redis_mode" "standalone"

  ok "inventory-growth updated successfully: ${inv_file}"
}

enforce_inventory_runtime_settings() {
  local inv_file="$1"
  local target_fqdn target_domain host_line remote_user controller_user controller_home controller_key known_hosts_file escaped_admin_password
  ensure_registry_credentials
  load_env
  remote_user="$(get_preferred_remote_user)"
  controller_user="$(get_controller_user)"
  controller_home="$(get_user_home "${controller_user}")"
  controller_key="$(get_controller_ssh_key)"
  known_hosts_file="${controller_home}/.ssh/known_hosts"
  target_fqdn="$(hostname -f 2>/dev/null || echo aap.localdomain)"
  target_domain="${target_fqdn#*.}"
  if [[ "${target_domain}" == "${target_fqdn}" || -z "${target_domain}" ]]; then
    target_domain="localdomain"
  fi
  host_line="${target_fqdn} ansible_host=${target_fqdn} real_hostname=${target_fqdn} ansible_user=${remote_user} ansible_ssh_private_key_file=${controller_key}"

  if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    read_secret_prompt ADMIN_PASSWORD "Enter platform admin password for runtime inventory values"
    save_env_kv "ADMIN_PASSWORD" "${ADMIN_PASSWORD}"
  fi
  escaped_admin_password="$(printf '%s' "${ADMIN_PASSWORD}" | sed -e 's/[\\/&]/\\&/g')"

  sed -E -i "s@aap\.example\.(com|org)@${target_fqdn}@g" "${inv_file}"
  sed -E -i "s@(^|[^[:alnum:]_])example\.(com|org)([^[:alnum:]_]|$)@\\1${target_domain}\\3@g" "${inv_file}"
  sed -E -i "s@\{\{[[:space:]]*admin_password[[:space:]]*\}\}@${escaped_admin_password}@g" "${inv_file}"

  awk -v normalized_host_line="${host_line}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    /^\[all:vars\]/ { in_all_vars = 1; print; next }
    /^\[/ { in_all_vars = 0; print; next }
    in_all_vars == 0 { print normalized_host_line; next }
    { print }
  ' "${inv_file}" > "${inv_file}.tmp" && mv "${inv_file}.tmp" "${inv_file}"

  if command -v runuser >/dev/null 2>&1 && id "${controller_user}" >/dev/null 2>&1; then
    runuser -u "${controller_user}" -- ssh-keygen -R aap >/dev/null 2>&1 || true
    runuser -u "${controller_user}" -- ssh-keygen -R "${target_fqdn}" >/dev/null 2>&1 || true
  elif command -v sudo >/dev/null 2>&1 && id "${controller_user}" >/dev/null 2>&1; then
    HOME="${controller_home}" sudo -u "${controller_user}" ssh-keygen -R aap >/dev/null 2>&1 || true
    HOME="${controller_home}" sudo -u "${controller_user}" ssh-keygen -R "${target_fqdn}" >/dev/null 2>&1 || true
  else
    ssh-keygen -f "${known_hosts_file}" -R aap >/dev/null 2>&1 || true
    ssh-keygen -f "${known_hosts_file}" -R "${target_fqdn}" >/dev/null 2>&1 || true
  fi

  upsert_inventory_var "${inv_file}" "ansible_user" "${remote_user}"
  upsert_inventory_var "${inv_file}" "ansible_become" "true"
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
  local runtime_host_line runtime_user runtime_become runtime_conn runtime_redis_mode remote_user controller_user controller_home controller_key
  local -a ansible_cmd
  install_dir="${DOWNLOAD_DIR}/${BUNDLE_DIR_NAME}"
  remote_user="$(get_preferred_remote_user)"
  controller_user="$(get_controller_user)"
  controller_home="$(get_user_home "${controller_user}")"
  controller_key="$(get_controller_ssh_key)"

  if [[ ! -d "${install_dir}" ]]; then
    err "Installation directory missing: ${install_dir}"
    return 1
  fi

  if [[ ! -f "${install_dir}/inventory-growth" ]]; then
    err "inventory-growth missing in ${install_dir}"
    return 1
  fi

  enforce_inventory_runtime_settings "${install_dir}/inventory-growth"

  runtime_host_line="$(awk '/^[[:space:]]*#/ || /^\[/ || /^[[:space:]]*$/ { next } { print; exit }' "${install_dir}/inventory-growth")"
  runtime_user="$(get_inventory_var "${install_dir}/inventory-growth" "ansible_user")"
  runtime_become="$(get_inventory_var "${install_dir}/inventory-growth" "ansible_become")"
  runtime_conn="$(get_inventory_var "${install_dir}/inventory-growth" "ansible_connection")"
  runtime_redis_mode="$(get_inventory_var "${install_dir}/inventory-growth" "redis_mode")"

  log "INFO" "Runtime inventory host line: ${runtime_host_line:-<not-found>}"
  log "INFO" "Runtime inventory vars: ansible_connection=${runtime_conn:-unset}, ansible_user=${runtime_user:-unset}, ansible_become=${runtime_become:-unset}"
  log "INFO" "Runtime inventory redis_mode=${runtime_redis_mode:-unset}"

  if id "${controller_user}" >/dev/null 2>&1; then
    chown -R "${controller_user}:${controller_user}" "${install_dir}" 2>/dev/null || true
  fi
  touch "${install_dir}/aap_install.log" 2>/dev/null || true

  log "Starting playbook execution: ansible.containerized_installer.${playbook_name}"
  (
    cd "${install_dir}"
    ansible_cmd=(
      ansible-playbook
      -i
      inventory-growth
      -u
      "${remote_user}"
      -c
      ssh
      -e
      "ansible_user=${remote_user}"
      -e
      ansible_become=true
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

    if command -v runuser >/dev/null 2>&1 && id "${controller_user}" >/dev/null 2>&1; then
      runuser -u "${controller_user}" -- env ANSIBLE_DEPRECATION_WARNINGS=False "${ansible_cmd[@]}"
    elif command -v sudo >/dev/null 2>&1 && id "${controller_user}" >/dev/null 2>&1; then
      HOME="${controller_home}" sudo -u "${controller_user}" env ANSIBLE_DEPRECATION_WARNINGS=False "${ansible_cmd[@]}"
    else
      warn "Neither runuser nor sudo was found; running ansible-playbook as current user."
      env ANSIBLE_DEPRECATION_WARNINGS=False "${ansible_cmd[@]}"
    fi
  )
}

run_install() {
  local choice playbook_name

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
  id admin >/dev/null 2>&1 && echo "admin user .......... PRESENT" || echo "admin user .......... MISSING"
  echo "hostname -f ......... $(hostname -f 2>/dev/null || echo unknown)"
  echo "hostname -d ......... $(hostname -d 2>/dev/null || echo unknown)"
  echo
  pause_enter
}

menu() {
  while true; do
    clear
    cat <<'EOF'
AAP 2.7-2 Production Installer Assistant
========================================
1) View installation checklist
2) Install required prework packages
3) Apply installation firewall/SELinux settings
4) Configure host identity (FQDN/domain + /etc/hosts)
5) Provision admin user (NOPASSWD sudo + SSH keys)
6) Capture RHSM credentials and tokens
7) Download setup bundle
8) Extract setup bundle
9) Update inventory-growth
10) Execute playbook (submenu)
11) View installation status
0) Exit

Enter step? for contextual guidance (example: 6?)
EOF

    read -r -p "Select menu option: " choice
    case "${choice}" in
      1) show_checklist ;;
      2) prework_packages; pause_enter ;;
      2\?) show_step_help 2 ;;
      3) disable_firewall_selinux; pause_enter ;;
      3\?) show_step_help 3 ;;
      4) set_fqdn_and_hosts; pause_enter ;;
      4\?) show_step_help 4 ;;
      5) setup_admin_user; pause_enter ;;
      5\?) show_step_help 5 ;;
      6) capture_credentials; pause_enter ;;
      6\?) show_step_help 6 ;;
      7) download_bundle; pause_enter ;;
      7\?) show_step_help 7 ;;
      8) extract_bundle; pause_enter ;;
      8\?) show_step_help 8 ;;
      9) modify_inventory_growth; pause_enter ;;
      9\?) show_step_help 9 ;;
      10) run_install; pause_enter ;;
      10\?) show_step_help 10 ;;
      11) show_status ;;
      0) exit 0 ;;
      *) warn "Invalid menu option."; pause_enter ;;
    esac
  done
}

main() {
  require_root
  mkdir -p "${DOWNLOAD_DIR}"
  touch "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  menu
}

main "$@"
